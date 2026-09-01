//! S3 backend gate against a local MinIO server.
//!
//! The MinIO instance is started and stopped by the build graph (a normal
//! process context; see the `s3-integration` step), never from inside this
//! test executable. The test runs the backend-agnostic object conformance
//! suite and a plan/read round trip against the endpoint. Run it through
//! `mise run s3-integration`.

const std = @import("std");
const ltx = @import("ltx");
const ltx_object = @import("ltx_object");
const ltx_replica = @import("ltx_replica");
const ltx_s3 = @import("ltx_s3");
const s3_options = @import("s3_options");

const minio_host = "127.0.0.1";
const minio_port: u16 = 19080;
const minio_root_user = "tester";
const minio_root_password = "tester-secret-and-long-enough";

const gate_codec_limits = ltx.Limits{
    .max_input_bytes = 4096,
    .max_output_bytes = 4096,
    .max_pages = 4,
    .max_page_size = 512,
    .max_compressed_page_size = 600,
    .max_page_index_bytes = 256,
    .max_page_index_entries = 4,
    .max_varint_bytes = 10,
    .max_transaction_span = 8,
};

const TestClock = struct {
    fn now_ms(_: *anyopaque) u64 {
        // SigV4 rejects clocks outside the skew window, so the gate signs
        // with the real clock rather than a fixed value.
        const now = std.Io.Timestamp.now(std.testing.io, .real);
        return @intCast(@divTrunc(now.nanoseconds, std.time.ns_per_ms));
    }
};

const MutableClock = struct {
    value_ms: u64,

    fn now_ms(context: *anyopaque) u64 {
        const self: *MutableClock = @ptrCast(@alignCast(context));
        return self.value_ms;
    }
};

/// Encodes one checksummed transition and returns its post-apply checksum.
fn encode_transition(
    min_txid: u64,
    max_txid: u64,
    pre_checksum: ltx.Checksum,
    commit: u32,
    pages: []const []const u8,
    writer: ltx.Writer,
) !ltx.Checksum {
    var compressed: [600]u8 = undefined;
    var compression: ltx.LZ4CompressionWorkspace = undefined;
    var index: [4]ltx.PageIndexEntry = undefined;
    var encoder = try ltx.Encoder.init(
        .v3,
        gate_codec_limits,
        writer,
        &compressed,
        &compression,
        &index,
    );
    try encoder.write_header(.{
        .flags = 0,
        .page_size = 512,
        .commit = commit,
        .min_txid = ltx.TXID.init(min_txid),
        .max_txid = ltx.TXID.init(max_txid),
        .timestamp_ms = @intCast(max_txid),
        .pre_apply_checksum = pre_checksum,
        .wal_offset = 0,
        .wal_size = 0,
        .wal_salt_1 = 0,
        .wal_salt_2 = 0,
        .node_id = 0,
    });
    var checksum_value = ltx.rolling_checksum_initial();
    var page_number: u32 = 1;
    for (pages) |page| {
        try encoder.write_page(page_number, page);
        checksum_value = try ltx.rolling_checksum_add(
            checksum_value,
            try ltx.checksum_page(page_number, page),
        );
        page_number += 1;
    }
    _ = try encoder.finish(checksum_value);
    return checksum_value;
}

const multipart_part_bytes = 5 * 1024 * 1024;

var plain_send_workspace: [2 * multipart_part_bytes]u8 = undefined;
var plain_clock_context: u8 = 0;

var s3_under_test: ?ltx_s3.S3Client = null;

fn init_plain_s3(send_workspace: []u8) !ltx_s3.S3Client {
    return ltx_s3.S3Client.init(
        std.testing.allocator,
        std.testing.io,
        .{
            .host = minio_host,
            .port = minio_port,
            .bucket = "ltx-gate",
            .access_key = minio_root_user,
            .secret_key = minio_root_password,
            .prefix = "replica",
            // The conformance suite lists three objects, forcing pagination.
            .max_keys_per_page = 2,
            .clock = .{
                .context = &plain_clock_context,
                .now_ms_fn = TestClock.now_ms,
            },
        },
        send_workspace,
    );
}

fn delete_identity(client: ltx_object.Client, identity: ltx.FileIdentity) !void {
    try client.delete(&.{.{
        .level = 0,
        .min_txid = identity.min_txid,
        .max_txid = identity.max_txid,
        .size_bytes = 0,
    }});
}

fn object_info(
    identity: ltx.FileIdentity,
    size_bytes: usize,
) ltx.FileInfo {
    return .{
        .level = 0,
        .min_txid = identity.min_txid,
        .max_txid = identity.max_txid,
        .size_bytes = @intCast(size_bytes),
    };
}

const ScriptedRangeResponse = struct {
    status: std.http.Status,
    headers: []const std.http.Header = &.{},
    body: []const u8,
    expected_range: []const u8 = "bytes=0-2",
    expected_etag: ?[]const u8 = null,
};

fn request_has_exact_header(
    request: *const std.http.Server.Request,
    name: []const u8,
    expected: []const u8,
) bool {
    var found: ?[]const u8 = null;
    var headers = request.iterateHeaders();
    while (headers.next()) |header| {
        if (!std.ascii.eqlIgnoreCase(header.name, name)) continue;
        if (found != null) return false;
        found = header.value;
    }
    return if (found) |value| std.mem.eql(u8, value, expected) else false;
}

fn request_lacks_header(
    request: *const std.http.Server.Request,
    name: []const u8,
) bool {
    var headers = request.iterateHeaders();
    while (headers.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, name)) return false;
    }
    return true;
}

fn serve_scripted_range_responses(
    server: *std.Io.net.Server,
    responses: []const ScriptedRangeResponse,
) !void {
    for (responses) |response| {
        var stream = try server.accept(std.testing.io);
        defer stream.close(std.testing.io);
        var read_buffer: [4096]u8 = undefined;
        var write_buffer: [4096]u8 = undefined;
        var stream_reader = stream.reader(std.testing.io, &read_buffer);
        var stream_writer = stream.writer(std.testing.io, &write_buffer);
        var http_server = std.http.Server.init(
            &stream_reader.interface,
            &stream_writer.interface,
        );
        var request = try http_server.receiveHead();
        const valid_request = request.head.method == .GET and
            request_has_exact_header(&request, "range", response.expected_range) and
            if (response.expected_etag) |etag|
                request_has_exact_header(&request, "if-match", etag)
            else
                request_lacks_header(&request, "if-match");
        try request.respond(response.body, .{
            .status = response.status,
            .keep_alive = false,
            .extra_headers = response.headers,
        });
        if (!valid_request) return error.TestUnexpectedResult;
    }
}

fn expect_scripted_range_error(
    response: ScriptedRangeResponse,
    expected_error: ltx_object.Error,
) !void {
    var address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var server = try address.listen(std.testing.io, .{});
    defer server.deinit(std.testing.io);
    const responses = [_]ScriptedRangeResponse{response};
    var server_task = std.testing.io.async(
        serve_scripted_range_responses,
        .{ &server, &responses },
    );
    defer _ = server_task.cancel(std.testing.io) catch {};

    var send_workspace: [64]u8 = undefined;
    var s3 = try ltx_s3.S3Client.init(
        std.testing.allocator,
        std.testing.io,
        .{
            .host = "127.0.0.1",
            .port = server.socket.address.getPort(),
            .bucket = "scripted-range",
            .access_key = "test-access",
            .secret_key = "test-secret",
            .clock = .{
                .context = &plain_clock_context,
                .now_ms_fn = TestClock.now_ms,
            },
        },
        &send_workspace,
    );
    defer s3.deinit();
    var destination: [3]u8 = undefined;
    const result = s3.client().read_range(
        object_info(.{ .min_txid = .init(1), .max_txid = .init(1) }, 6),
        0,
        &destination,
    );
    try server_task.cancel(std.testing.io);
    try std.testing.expectError(expected_error, result);
}

const ScriptedMultipartAction = union(enum) {
    respond: struct {
        status: std.http.Status,
        headers: []const std.http.Header = &.{},
        body: []const u8 = "",
    },
    drop_after_body,
    drop_response_body,
};

const ScriptedMultipartRequest = struct {
    method: std.http.Method,
    target: []const u8,
    action: ScriptedMultipartAction,
};

fn serve_scripted_multipart_request(
    server: *std.Io.net.Server,
    scripted: ScriptedMultipartRequest,
) !void {
    var stream = try server.accept(std.testing.io);
    defer stream.close(std.testing.io);
    var read_buffer: [8192]u8 = undefined;
    var write_buffer: [8192]u8 = undefined;
    var body_buffer: [4096]u8 = undefined;
    var stream_reader = stream.reader(std.testing.io, &read_buffer);
    var stream_writer = stream.writer(std.testing.io, &write_buffer);
    var http_server = std.http.Server.init(
        &stream_reader.interface,
        &stream_writer.interface,
    );
    var request = try http_server.receiveHead();
    const valid_request = request.head.method == scripted.method and
        std.mem.eql(u8, request.head.target, scripted.target);
    if (request.head.method.requestHasBody()) {
        const body_reader = try request.readerExpectContinue(&body_buffer);
        _ = try body_reader.discardRemaining();
    }
    if (!valid_request) return error.TestUnexpectedResult;
    switch (scripted.action) {
        .respond => |response| try request.respond(response.body, .{
            .status = response.status,
            .keep_alive = false,
            .extra_headers = response.headers,
        }),
        .drop_after_body => {},
        .drop_response_body => {
            try request.server.out.writeAll(
                "HTTP/1.1 200 OK\r\n" ++
                    "content-length: 128\r\n" ++
                    "connection: close\r\n\r\n" ++
                    "<CompleteMultipartUploadResult>",
            );
            try request.server.out.flush();
        },
    }
}

fn serve_scripted_multipart_requests(
    server: *std.Io.net.Server,
    requests: []const ScriptedMultipartRequest,
) !void {
    for (requests) |request| {
        try serve_scripted_multipart_request(server, request);
    }
}

const scripted_multipart_identity = ltx.FileIdentity{
    .min_txid = .init(71),
    .max_txid = .init(71),
};
const scripted_multipart_key =
    "/scripted-multipart/0000/0000000000000047-0000000000000047.ltx";
const scripted_upload_id = "scripted-upload";
const scripted_initiation_target = scripted_multipart_key ++ "?uploads=";
const scripted_upload_target =
    scripted_multipart_key ++ "?uploadId=" ++ scripted_upload_id;
const scripted_part_one_target =
    scripted_multipart_key ++ "?partNumber=1&uploadId=" ++ scripted_upload_id;
const scripted_part_two_target =
    scripted_multipart_key ++ "?partNumber=2&uploadId=" ++ scripted_upload_id;
const scripted_initiation_body =
    "<InitiateMultipartUploadResult><UploadId>" ++
    scripted_upload_id ++
    "</UploadId></InitiateMultipartUploadResult>";
const scripted_oversized_completion_body: [64 * 1024 + 1]u8 = @splat('x');
const scripted_part_headers = [_]std.http.Header{.{
    .name = "etag",
    .value = "\"scripted-part\"",
}};
const scripted_begin_success = ScriptedMultipartRequest{
    .method = .POST,
    .target = scripted_initiation_target,
    .action = .{ .respond = .{
        .status = .ok,
        .body = scripted_initiation_body,
    } },
};
const scripted_part_one_success = ScriptedMultipartRequest{
    .method = .PUT,
    .target = scripted_part_one_target,
    .action = .{ .respond = .{
        .status = .ok,
        .headers = &scripted_part_headers,
    } },
};
const scripted_part_two_success = ScriptedMultipartRequest{
    .method = .PUT,
    .target = scripted_part_two_target,
    .action = .{ .respond = .{
        .status = .ok,
        .headers = &scripted_part_headers,
    } },
};
const scripted_abort_clean = ScriptedMultipartRequest{
    .method = .DELETE,
    .target = scripted_upload_target,
    .action = .{ .respond = .{ .status = .not_found } },
};

fn init_scripted_s3(
    port: u16,
    send_workspace: []u8,
    retry: ?ltx_s3.RetryPolicy,
) !ltx_s3.S3Client {
    return ltx_s3.S3Client.init(
        std.testing.allocator,
        std.testing.io,
        .{
            .host = "127.0.0.1",
            .port = port,
            .bucket = "scripted-multipart",
            .access_key = "test-access",
            .secret_key = "test-secret",
            .clock = .{
                .context = &plain_clock_context,
                .now_ms_fn = TestClock.now_ms,
            },
            .retry = retry,
        },
        send_workspace,
    );
}

fn expect_indeterminate_multipart_completion(
    completion_action: ScriptedMultipartAction,
) !void {
    var address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var server = try address.listen(std.testing.io, .{});
    defer server.deinit(std.testing.io);
    const requests = [_]ScriptedMultipartRequest{
        scripted_begin_success,
        scripted_part_one_success,
        .{
            .method = .POST,
            .target = scripted_upload_target,
            .action = completion_action,
        },
        scripted_abort_clean,
    };
    var server_task = std.testing.io.async(
        serve_scripted_multipart_requests,
        .{ &server, &requests },
    );
    defer _ = server_task.cancel(std.testing.io) catch {};

    var retry_probe = RetryProbe{};
    var send_workspace: [64]u8 = undefined;
    var s3 = try init_scripted_s3(
        server.socket.address.getPort(),
        &send_workspace,
        .{
            .context = &retry_probe,
            .next_delay_ms_fn = RetryProbe.next,
            .sleep_ms_fn = RetryProbe.sleep,
            .max_attempts = 3,
        },
    );
    defer s3.deinit();

    try s3.begin_multipart(0, scripted_multipart_identity, 10_000);
    try s3.put_part(1, "tail");
    try std.testing.expectError(
        error.PublicationIndeterminate,
        s3.complete_multipart(),
    );
    try std.testing.expect(s3.multipart != null);
    try std.testing.expectError(
        error.InvalidState,
        s3.client().begin_write(0, scripted_multipart_identity, 10_001),
    );
    try s3.abort_multipart();
    try std.testing.expect(s3.multipart == null);
    try std.testing.expectEqual(@as(u32, 0), retry_probe.calls);
    try server_task.await(std.testing.io);
}

test "scripted multipart completion lost acknowledgement is indeterminate" {
    try expect_indeterminate_multipart_completion(.drop_after_body);
}

test "scripted multipart completion truncated acknowledgement is indeterminate" {
    try expect_indeterminate_multipart_completion(.drop_response_body);
}

test "scripted multipart completion 5xx is indeterminate and not retried" {
    try expect_indeterminate_multipart_completion(.{ .respond = .{
        .status = .internal_server_error,
    } });
}

test "scripted multipart completion malformed success is indeterminate" {
    try expect_indeterminate_multipart_completion(.{ .respond = .{
        .status = .ok,
        .body = "<NotACompletionResult/>",
    } });
}

test "scripted multipart completion oversized success is indeterminate" {
    try expect_indeterminate_multipart_completion(.{ .respond = .{
        .status = .ok,
        .body = &scripted_oversized_completion_body,
    } });
}

test "scripted multipart initiation lost acknowledgement is not retried" {
    var address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var server = try address.listen(std.testing.io, .{});
    defer server.deinit(std.testing.io);
    const requests = [_]ScriptedMultipartRequest{.{
        .method = .POST,
        .target = scripted_initiation_target,
        .action = .drop_after_body,
    }};
    var server_task = std.testing.io.async(
        serve_scripted_multipart_requests,
        .{ &server, &requests },
    );
    defer _ = server_task.cancel(std.testing.io) catch {};

    var retry_probe = RetryProbe{};
    var send_workspace: [64]u8 = undefined;
    var s3 = try init_scripted_s3(server.socket.address.getPort(), &send_workspace, .{
        .context = &retry_probe,
        .next_delay_ms_fn = RetryProbe.next,
        .sleep_ms_fn = RetryProbe.sleep,
        .max_attempts = 3,
    });
    defer s3.deinit();

    try std.testing.expectError(
        error.StorageFailure,
        s3.begin_multipart(0, scripted_multipart_identity, 10_100),
    );
    try std.testing.expect(s3.multipart == null);
    try std.testing.expectEqual(@as(u32, 0), retry_probe.calls);
    var replacement = try s3.client().begin_write(
        0,
        scripted_multipart_identity,
        10_101,
    );
    replacement.abort();
    try server_task.await(std.testing.io);
}

test "scripted small write session lost acknowledgement is indeterminate" {
    var address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var server = try address.listen(std.testing.io, .{});
    defer server.deinit(std.testing.io);
    const requests = [_]ScriptedMultipartRequest{.{
        .method = .PUT,
        .target = scripted_multipart_key,
        .action = .drop_after_body,
    }};
    var server_task = std.testing.io.async(
        serve_scripted_multipart_requests,
        .{ &server, &requests },
    );
    defer _ = server_task.cancel(std.testing.io) catch {};

    var retry_probe = RetryProbe{};
    var send_workspace: [64]u8 = undefined;
    var s3 = try init_scripted_s3(server.socket.address.getPort(), &send_workspace, .{
        .context = &retry_probe,
        .next_delay_ms_fn = RetryProbe.next,
        .sleep_ms_fn = RetryProbe.sleep,
        .max_attempts = 3,
    });
    defer s3.deinit();
    var session = try s3.client().begin_write(
        0,
        scripted_multipart_identity,
        10_150,
    );
    try session.writer().write_all("small payload");
    try std.testing.expectError(error.PublicationIndeterminate, session.finish());
    try std.testing.expectEqual(
        ltx_object.WriteSessionState.failed,
        session.current_state(),
    );
    try std.testing.expect(s3.write_session == null);
    try std.testing.expectEqual(@as(u32, 0), retry_probe.calls);
    var replacement = try s3.client().begin_write(
        0,
        scripted_multipart_identity,
        10_151,
    );
    replacement.abort();
    try server_task.await(std.testing.io);
}

test "scripted multipart part and abort failures retain cleanup identity" {
    var address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var server = try address.listen(std.testing.io, .{});
    defer server.deinit(std.testing.io);
    const requests = [_]ScriptedMultipartRequest{
        scripted_begin_success,
        .{
            .method = .PUT,
            .target = scripted_part_one_target,
            .action = .drop_after_body,
        },
        .{
            .method = .DELETE,
            .target = scripted_upload_target,
            .action = .{ .respond = .{ .status = .internal_server_error } },
        },
        scripted_abort_clean,
    };
    var server_task = std.testing.io.async(
        serve_scripted_multipart_requests,
        .{ &server, &requests },
    );
    defer _ = server_task.cancel(std.testing.io) catch {};

    var send_workspace: [64]u8 = undefined;
    var s3 = try init_scripted_s3(
        server.socket.address.getPort(),
        &send_workspace,
        null,
    );
    defer s3.deinit();
    try s3.begin_multipart(0, scripted_multipart_identity, 10_200);
    try std.testing.expectError(error.StorageFailure, s3.put_part(1, "tail"));
    try std.testing.expectError(error.StorageFailure, s3.abort_multipart());
    try std.testing.expect(s3.multipart != null);
    try std.testing.expectError(
        error.InvalidState,
        s3.client().begin_write(0, scripted_multipart_identity, 10_201),
    );
    try s3.abort_multipart();
    try std.testing.expect(s3.multipart == null);
    try server_task.await(std.testing.io);
}

test "scripted write session poisons and retains failed multipart cleanup" {
    @memset(&multipart_a, 0x8c);
    @memset(&multipart_tail, 0xc8);
    var address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var server = try address.listen(std.testing.io, .{});
    defer server.deinit(std.testing.io);
    const requests = [_]ScriptedMultipartRequest{
        scripted_begin_success,
        scripted_part_one_success,
        scripted_part_two_success,
        .{
            .method = .POST,
            .target = scripted_upload_target,
            .action = .drop_after_body,
        },
        .{
            .method = .DELETE,
            .target = scripted_upload_target,
            .action = .{ .respond = .{ .status = .internal_server_error } },
        },
        scripted_abort_clean,
    };
    var server_task = std.testing.io.async(
        serve_scripted_multipart_requests,
        .{ &server, &requests },
    );
    defer _ = server_task.cancel(std.testing.io) catch {};

    var s3 = try init_scripted_s3(
        server.socket.address.getPort(),
        &automatic_send_workspace,
        null,
    );
    defer s3.deinit();
    var session = try s3.client().begin_write(
        0,
        scripted_multipart_identity,
        10_300,
    );
    try session.writer().write_all(&multipart_a);
    try session.writer().write_all(&multipart_tail);
    try std.testing.expectError(error.PublicationIndeterminate, session.finish());
    try std.testing.expectEqual(
        ltx_object.WriteSessionState.failed,
        session.current_state(),
    );
    try std.testing.expect(s3.write_session == null);
    try std.testing.expect(s3.multipart != null);
    try std.testing.expectError(error.InvalidState, session.finish());
    try std.testing.expectError(error.OutputFailure, session.writer().write_all("late"));
    try std.testing.expectError(
        error.InvalidState,
        s3.client().begin_write(0, scripted_multipart_identity, 10_301),
    );
    try s3.abort_multipart();
    try std.testing.expect(s3.multipart == null);
    try server_task.await(std.testing.io);
}

const generation_one = "\"generation-one\"";
const generation_two = "\"generation-two\"";

const valid_range_headers = [_]std.http.Header{
    .{ .name = "content-range", .value = "bytes 0-2/6" },
    .{ .name = "etag", .value = generation_one },
};

const valid_second_range_headers = [_]std.http.Header{
    .{ .name = "content-range", .value = "bytes 3-5/6" },
    .{ .name = "etag", .value = generation_one },
};

const changed_second_range_headers = [_]std.http.Header{
    .{ .name = "content-range", .value = "bytes 3-5/6" },
    .{ .name = "etag", .value = generation_two },
};

const duplicate_range_headers = [_]std.http.Header{
    .{ .name = "content-range", .value = "bytes 0-2/6" },
    .{ .name = "Content-Range", .value = "bytes 0-2/6" },
    .{ .name = "etag", .value = generation_one },
};

const mismatched_interval_headers = [_]std.http.Header{
    .{ .name = "content-range", .value = "bytes 1-3/6" },
    .{ .name = "etag", .value = generation_one },
};

const mismatched_total_headers = [_]std.http.Header{
    .{ .name = "content-range", .value = "bytes 0-2/7" },
    .{ .name = "etag", .value = generation_one },
};

const second_mismatched_total_headers = [_]std.http.Header{
    .{ .name = "content-range", .value = "bytes 3-5/7" },
    .{ .name = "etag", .value = generation_one },
};

const range_without_etag_headers = [_]std.http.Header{.{
    .name = "content-range",
    .value = "bytes 0-2/6",
}};

const duplicate_etag_headers = [_]std.http.Header{
    .{ .name = "content-range", .value = "bytes 0-2/6" },
    .{ .name = "etag", .value = generation_one },
    .{ .name = "ETag", .value = generation_one },
};

const empty_etag_headers = [_]std.http.Header{
    .{ .name = "content-range", .value = "bytes 0-2/6" },
    .{ .name = "etag", .value = "" },
};

const oversized_etag_value: [ltx_object.max_read_generation_bytes + 1]u8 =
    @splat('e');
const oversized_etag_headers = [_]std.http.Header{
    .{ .name = "content-range", .value = "bytes 0-2/6" },
    .{ .name = "etag", .value = &oversized_etag_value },
};

test "scripted S3 range read rejects a whole-object success response" {
    try expect_scripted_range_error(.{
        .status = .ok,
        .body = "abc",
    }, error.StorageFailure);
}

test "scripted S3 range read requires exactly one Content-Range header" {
    try expect_scripted_range_error(.{
        .status = .partial_content,
        .headers = &[_]std.http.Header{.{
            .name = "etag",
            .value = generation_one,
        }},
        .body = "abc",
    }, error.StorageFailure);
    try expect_scripted_range_error(.{
        .status = .partial_content,
        .headers = &duplicate_range_headers,
        .body = "abc",
    }, error.StorageFailure);
}

test "scripted S3 range read validates the complete Content-Range value" {
    try expect_scripted_range_error(.{
        .status = .partial_content,
        .headers = &mismatched_interval_headers,
        .body = "abc",
    }, error.StorageFailure);
    try expect_scripted_range_error(.{
        .status = .partial_content,
        .headers = &mismatched_total_headers,
        .body = "abc",
    }, error.ObjectChanged);
}

test "scripted S3 range read rejects short and oversized response bodies" {
    try expect_scripted_range_error(.{
        .status = .partial_content,
        .headers = &valid_range_headers,
        .body = "ab",
    }, error.StorageFailure);
    try expect_scripted_range_error(.{
        .status = .partial_content,
        .headers = &valid_range_headers,
        .body = "abcd",
    }, error.StorageFailure);
}

test "scripted S3 range read requires one bounded nonempty ETag" {
    try expect_scripted_range_error(.{
        .status = .partial_content,
        .headers = &range_without_etag_headers,
        .body = "abc",
    }, error.StorageFailure);
    try expect_scripted_range_error(.{
        .status = .partial_content,
        .headers = &duplicate_etag_headers,
        .body = "abc",
    }, error.StorageFailure);
    try expect_scripted_range_error(.{
        .status = .partial_content,
        .headers = &empty_etag_headers,
        .body = "abc",
    }, error.StorageFailure);
    try expect_scripted_range_error(.{
        .status = .partial_content,
        .headers = &oversized_etag_headers,
        .body = "abc",
    }, error.StorageFailure);
}

test "scripted S3 object reader binds ETag and sends If-Match on refill" {
    var address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var server = try address.listen(std.testing.io, .{});
    defer server.deinit(std.testing.io);
    const responses = [_]ScriptedRangeResponse{
        .{
            .status = .partial_content,
            .headers = &valid_range_headers,
            .body = "abc",
        },
        .{
            .status = .partial_content,
            .headers = &valid_second_range_headers,
            .body = "def",
            .expected_range = "bytes=3-5",
            .expected_etag = generation_one,
        },
    };
    var server_task = std.testing.io.async(
        serve_scripted_range_responses,
        .{ &server, &responses },
    );
    defer _ = server_task.cancel(std.testing.io) catch {};

    var send_workspace: [64]u8 = undefined;
    var s3 = try ltx_s3.S3Client.init(
        std.testing.allocator,
        std.testing.io,
        .{
            .host = "127.0.0.1",
            .port = server.socket.address.getPort(),
            .bucket = "scripted-reader",
            .access_key = "test-access",
            .secret_key = "test-secret",
            .clock = .{
                .context = &plain_clock_context,
                .now_ms_fn = TestClock.now_ms,
            },
        },
        &send_workspace,
    );
    defer s3.deinit();

    const info = object_info(.{ .min_txid = .init(2), .max_txid = .init(2) }, 6);
    var workspace: [3]u8 = undefined;
    var source = try ltx_object.ObjectReader.init(s3.client(), info, &workspace);
    const reader = source.reader();
    var output: [6]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 3), try reader.read(&output));
    try std.testing.expectEqual(@as(usize, 3), try reader.read(output[3..]));
    try std.testing.expectEqualStrings("abcdef", &output);
    try std.testing.expect(try reader.at_end());
    try std.testing.expect(source.failure() == null);
    try server_task.await(std.testing.io);
}

fn expect_scripted_refill_error(
    second_response: ScriptedRangeResponse,
    expected_error: ltx_object.Error,
) !void {
    var address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var server = try address.listen(std.testing.io, .{});
    defer server.deinit(std.testing.io);
    const responses = [_]ScriptedRangeResponse{
        .{
            .status = .partial_content,
            .headers = &valid_range_headers,
            .body = "abc",
        },
        second_response,
    };
    var server_task = std.testing.io.async(
        serve_scripted_range_responses,
        .{ &server, &responses },
    );
    defer _ = server_task.cancel(std.testing.io) catch {};

    var send_workspace: [64]u8 = undefined;
    var s3 = try ltx_s3.S3Client.init(
        std.testing.allocator,
        std.testing.io,
        .{
            .host = "127.0.0.1",
            .port = server.socket.address.getPort(),
            .bucket = "scripted-reader",
            .access_key = "test-access",
            .secret_key = "test-secret",
            .clock = .{
                .context = &plain_clock_context,
                .now_ms_fn = TestClock.now_ms,
            },
        },
        &send_workspace,
    );
    defer s3.deinit();

    const info = object_info(.{ .min_txid = .init(3), .max_txid = .init(3) }, 6);
    var workspace: [3]u8 = undefined;
    var source = try ltx_object.ObjectReader.init(s3.client(), info, &workspace);
    const reader = source.reader();
    var first: [3]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 3), try reader.read(&first));
    try std.testing.expectEqualStrings("abc", &first);
    var second: [3]u8 = @splat(0xcc);
    try std.testing.expectError(error.InputFailure, reader.read(&second));
    try std.testing.expectEqual(expected_error, source.failure().?);
    try std.testing.expectEqualSlices(u8, &([_]u8{0xcc} ** 3), &second);
    try server_task.await(std.testing.io);
}

test "scripted S3 conditional refill maps precondition failure to object change" {
    try expect_scripted_refill_error(.{
        .status = .precondition_failed,
        .body = "",
        .expected_range = "bytes=3-5",
        .expected_etag = generation_one,
    }, error.ObjectChanged);
}

test "scripted S3 successful refill rejects a changed response ETag" {
    try expect_scripted_refill_error(.{
        .status = .partial_content,
        .headers = &changed_second_range_headers,
        .body = "def",
        .expected_range = "bytes=3-5",
        .expected_etag = generation_one,
    }, error.ObjectChanged);
}

test "scripted S3 object reader poisons without exposing failed range bytes" {
    var address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var server = try address.listen(std.testing.io, .{});
    var server_open = true;
    defer if (server_open) server.deinit(std.testing.io);
    const responses = [_]ScriptedRangeResponse{
        .{
            .status = .partial_content,
            .headers = &valid_range_headers,
            .body = "abc",
        },
        .{
            .status = .partial_content,
            .headers = &second_mismatched_total_headers,
            .body = "def",
            .expected_range = "bytes=3-5",
            .expected_etag = generation_one,
        },
    };
    var server_task = std.testing.io.async(
        serve_scripted_range_responses,
        .{ &server, &responses },
    );
    defer _ = server_task.cancel(std.testing.io) catch {};

    var send_workspace: [64]u8 = undefined;
    var s3 = try ltx_s3.S3Client.init(
        std.testing.allocator,
        std.testing.io,
        .{
            .host = "127.0.0.1",
            .port = server.socket.address.getPort(),
            .bucket = "scripted-reader",
            .access_key = "test-access",
            .secret_key = "test-secret",
            .clock = .{
                .context = &plain_clock_context,
                .now_ms_fn = TestClock.now_ms,
            },
        },
        &send_workspace,
    );
    defer s3.deinit();

    const info = object_info(.{ .min_txid = .init(2), .max_txid = .init(2) }, 6);
    var workspace: [3]u8 = undefined;
    var source = try ltx_object.ObjectReader.init(s3.client(), info, &workspace);
    const reader = source.reader();
    var output: [6]u8 = @splat(0xcc);
    try std.testing.expectEqual(@as(usize, 3), try reader.read(&output));
    try std.testing.expectEqualStrings("abc", output[0..3]);
    try std.testing.expectError(error.InputFailure, reader.read(output[3..]));
    try server_task.cancel(std.testing.io);
    server.deinit(std.testing.io);
    server_open = false;
    try std.testing.expectEqual(error.ObjectChanged, source.failure().?);
    try std.testing.expectEqualSlices(u8, &([_]u8{0xcc} ** 3), output[3..]);
    try std.testing.expectEqualStrings("def", &workspace);

    var late: [3]u8 = @splat(0x5a);
    try std.testing.expectError(error.InputFailure, reader.read(&late));
    try std.testing.expectEqualSlices(u8, &([_]u8{0x5a} ** 3), &late);
    try std.testing.expectEqual(error.ObjectChanged, source.failure().?);
    try std.testing.expectError(error.InputFailure, reader.at_end());
}

test "listing stops at the configured remote page budget" {
    var send_workspace: [64]u8 = undefined;
    var s3 = try ltx_s3.S3Client.init(
        std.testing.allocator,
        std.testing.io,
        .{
            .host = minio_host,
            .port = minio_port,
            .bucket = "ltx-gate",
            .access_key = minio_root_user,
            .secret_key = minio_root_password,
            .prefix = "listing-limit",
            .max_keys_per_page = 1,
            .max_listing_pages = 1,
            .clock = .{
                .context = &plain_clock_context,
                .now_ms_fn = TestClock.now_ms,
            },
        },
        &send_workspace,
    );
    defer s3.deinit();
    try s3.ensure_bucket();
    const client = s3.client();
    const first = ltx.FileIdentity{
        .min_txid = ltx.TXID.init(61),
        .max_txid = ltx.TXID.init(61),
    };
    const second = ltx.FileIdentity{
        .min_txid = ltx.TXID.init(62),
        .max_txid = ltx.TXID.init(62),
    };
    try delete_identity(client, first);
    defer delete_identity(client, first) catch {};
    try delete_identity(client, second);
    defer delete_identity(client, second) catch {};
    try client.write(0, first, 1, "first");
    try client.write(0, second, 2, "second");

    var infos: [2]ltx.FileInfo = undefined;
    try std.testing.expectError(
        error.ListingPageLimitExceeded,
        client.list(0, ltx.TXID.init(0), &infos),
    );
    s3.config.max_listing_pages = 2;
    try std.testing.expectEqual(
        @as(usize, 2),
        (try client.list(0, ltx.TXID.init(0), &infos)).len,
    );
}

test "range and whole reads honor the listed object size" {
    var send_workspace: [64]u8 = undefined;
    var s3 = try ltx_s3.S3Client.init(
        std.testing.allocator,
        std.testing.io,
        .{
            .host = minio_host,
            .port = minio_port,
            .bucket = "ltx-gate",
            .access_key = minio_root_user,
            .secret_key = minio_root_password,
            .prefix = "range-read",
            .clock = .{
                .context = &plain_clock_context,
                .now_ms_fn = TestClock.now_ms,
            },
        },
        &send_workspace,
    );
    defer s3.deinit();
    try s3.ensure_bucket();

    const client = s3.client();
    const identity = ltx.FileIdentity{
        .min_txid = ltx.TXID.init(1),
        .max_txid = ltx.TXID.init(1),
    };
    const payload = "range-0123456789-end";
    try delete_identity(client, identity);
    defer delete_identity(client, identity) catch {};
    try client.write(0, identity, 1, payload);

    var listed_storage: [1]ltx.FileInfo = undefined;
    const listed = try client.list(0, ltx.TXID.init(0), &listed_storage);
    try std.testing.expectEqual(@as(usize, 1), listed.len);
    try std.testing.expectEqual(@as(u64, payload.len), listed[0].size_bytes);

    var middle: [3]u8 = undefined;
    try client.read_range(listed[0], 8, &middle);
    try std.testing.expectEqualStrings("234", &middle);
    var one: [1]u8 = undefined;
    try client.read_range(listed[0], payload.len - 1, &one);
    try std.testing.expectEqualStrings("d", &one);

    var all_storage: [64]u8 = undefined;
    try std.testing.expectEqualStrings(
        payload,
        try client.read_all(listed[0], &all_storage),
    );

    var stale = listed[0];
    stale.size_bytes += 1;
    try std.testing.expectError(
        error.ObjectChanged,
        client.read_range(stale, 0, &one),
    );
}

test "object reader rejects equal-size S3 replacement between refills" {
    var send_workspace: [64]u8 = undefined;
    var s3 = try ltx_s3.S3Client.init(
        std.testing.allocator,
        std.testing.io,
        .{
            .host = minio_host,
            .port = minio_port,
            .bucket = "ltx-gate",
            .access_key = minio_root_user,
            .secret_key = minio_root_password,
            .prefix = "generation-read",
            .clock = .{
                .context = &plain_clock_context,
                .now_ms_fn = TestClock.now_ms,
            },
        },
        &send_workspace,
    );
    defer s3.deinit();
    try s3.ensure_bucket();

    const client = s3.client();
    const identity = ltx.FileIdentity{
        .min_txid = ltx.TXID.init(91),
        .max_txid = ltx.TXID.init(91),
    };
    try delete_identity(client, identity);
    defer delete_identity(client, identity) catch {};
    try client.write(0, identity, 1, "abcdef");

    const info = object_info(identity, 6);
    var workspace: [3]u8 = undefined;
    var source = try ltx_object.ObjectReader.init(client, info, &workspace);
    const reader = source.reader();
    var first: [3]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 3), try reader.read(&first));
    try std.testing.expectEqualStrings("abc", &first);

    try client.write(0, identity, 2, "uvwxyz");
    var second: [3]u8 = @splat(0xcc);
    try std.testing.expectError(error.InputFailure, reader.read(&second));
    try std.testing.expectEqual(error.ObjectChanged, source.failure().?);
    try std.testing.expectEqualSlices(u8, &([_]u8{0xcc} ** 3), &second);
}

test "s3 backend passes the conformance suite and a plan round trip" {
    const allocator = std.testing.allocator;

    s3_under_test = try ltx_s3.S3Client.init(
        allocator,
        std.testing.io,
        .{
            .host = minio_host,
            .port = minio_port,
            .bucket = "ltx-gate",
            .access_key = minio_root_user,
            .secret_key = minio_root_password,
            .prefix = "replica",
            .clock = .{
                .context = &plain_clock_context,
                .now_ms_fn = TestClock.now_ms,
            },
        },
        &plain_send_workspace,
    );
    const s3 = &s3_under_test.?;
    defer s3.deinit();
    try s3.ensure_bucket();
    try ltx_object.run_conformance(s3.client());

    // Plan round trip: a checksummed snapshot plus a contiguous incremental,
    // planned from real S3 listings and read back byte-identically.
    const page_one = [_]u8{0xa5} ** 512;
    const page_two = [_]u8{0x5a} ** 512;
    var snapshot_storage: [4096]u8 = undefined;
    var snapshot_sink = ltx.SliceWriter.init(&snapshot_storage);
    const snapshot_checksum = try encode_transition(
        1,
        1,
        ltx.Checksum.init(0),
        2,
        &.{ &page_one, &page_two },
        snapshot_sink.writer(),
    );
    var incremental_storage: [4096]u8 = undefined;
    var incremental_sink = ltx.SliceWriter.init(&incremental_storage);
    _ = try encode_transition(
        2,
        2,
        snapshot_checksum,
        2,
        &.{ &page_one, &page_two },
        incremental_sink.writer(),
    );

    const client = s3.client();
    try client.write(0, .{
        .min_txid = ltx.TXID.init(1),
        .max_txid = ltx.TXID.init(1),
    }, 1000, snapshot_sink.written());
    try client.write(0, .{
        .min_txid = ltx.TXID.init(2),
        .max_txid = ltx.TXID.init(2),
    }, 2000, incremental_sink.written());

    var buffers: [ltx.snapshot_level + 1][8]ltx.FileInfo = undefined;
    var lists: [ltx.snapshot_level + 1][]const ltx.FileInfo = undefined;
    for (0..lists.len) |level| {
        lists[level] = try client.list(@intCast(level), ltx.TXID.init(0), &buffers[level]);
    }
    try std.testing.expectEqual(@as(usize, 2), lists[0].len);
    var plan_storage: [8]ltx.FileInfo = undefined;
    const plan = try ltx_replica.calc_restore_plan(&lists, ltx.TXID.init(0), &plan_storage);
    try std.testing.expectEqual(@as(usize, 2), plan.len);

    var object_storage: [4096]u8 = undefined;
    const first = try client.read_all(plan[0], &object_storage);
    try std.testing.expectEqualSlices(u8, snapshot_sink.written(), first);

    // Conditional writes: the first fence claim wins, the second contender
    // loses, and the plain overwrite remains available.
    const fence = ltx.FileIdentity{
        .min_txid = ltx.TXID.init(99),
        .max_txid = ltx.TXID.init(99),
    };
    try s3.put_if_absent(0, fence, 5000, "claim");
    try std.testing.expectError(
        error.ObjectExists,
        s3.put_if_absent(0, fence, 5100, "contender"),
    );
    const claimed = try client.read_all(object_info(fence, "claim".len), &object_storage);
    try std.testing.expectEqualStrings("claim", claimed);
    try client.write(0, fence, 5200, "overwrite");
}

test "s3 backend passes the conformance suite over TLS" {
    if (s3_options.minio_ca.len == 0 or s3_options.minio_tls_port == 0) {
        // The TLS lane is configured by tools/s3_gate/run.sh; plain manual
        // runs without certificates skip it.
        return error.SkipZigTest;
    }
    const allocator = std.testing.allocator;
    const current = std.Io.Timestamp.now(std.testing.io, .real);
    var clock = MutableClock{
        .value_ms = @intCast(@divTrunc(current.nanoseconds, std.time.ns_per_ms)),
    };
    var send_workspace: [64 * 1024]u8 = undefined;
    var s3 = try ltx_s3.S3Client.init(
        allocator,
        std.testing.io,
        .{
            // The TLS certificate carries a DNS SAN, which is what the
            // standard-library host verification checks.
            .host = "localhost",
            .port = s3_options.minio_tls_port,
            .bucket = "ltx-gate-tls",
            .access_key = minio_root_user,
            .secret_key = minio_root_password,
            .prefix = "replica",
            .use_tls = true,
            .ca_file = s3_options.minio_ca,
            .clock = .{
                .context = &clock,
                .now_ms_fn = MutableClock.now_ms,
            },
        },
        &send_workspace,
    );
    defer s3.deinit();
    clock.value_ms += 1_000;
    try s3.ensure_bucket();
    try std.testing.expectEqual(
        @as(i96, clock.value_ms) * std.time.ns_per_ms,
        s3.http.now.?.nanoseconds,
    );
    try ltx_object.run_conformance(s3.client());
}

test "TLS delete completes without waiting for the peer idle timeout" {
    if (s3_options.minio_ca.len == 0 or s3_options.minio_tls_port == 0) {
        return error.SkipZigTest;
    }
    var clock_context: u8 = 0;
    var send_workspace: [1024]u8 = undefined;
    var s3 = try ltx_s3.S3Client.init(
        std.testing.allocator,
        std.testing.io,
        .{
            .host = "localhost",
            .port = s3_options.minio_tls_port,
            .bucket = "ltx-gate-tls-delete",
            .access_key = minio_root_user,
            .secret_key = minio_root_password,
            .use_tls = true,
            .ca_file = s3_options.minio_ca,
            .clock = .{
                .context = &clock_context,
                .now_ms_fn = TestClock.now_ms,
            },
        },
        &send_workspace,
    );
    defer s3.deinit();
    try s3.ensure_bucket();

    const identity = ltx.FileIdentity{
        .min_txid = ltx.TXID.init(1),
        .max_txid = ltx.TXID.init(1),
    };
    const client = s3.client();
    try client.write(0, identity, 1000, "delete-probe");
    try client.delete(&.{.{
        .level = 0,
        .min_txid = identity.min_txid,
        .max_txid = identity.max_txid,
        .size_bytes = 0,
    }});
}

var multipart_a: [multipart_part_bytes]u8 = undefined;
var multipart_b: [multipart_part_bytes]u8 = undefined;
var multipart_tail: [1024]u8 = undefined;
var multipart_recv: [2 * multipart_part_bytes + 1024]u8 = undefined;
var automatic_send_workspace: [multipart_part_bytes]u8 = undefined;

test "multipart upload streams parts into one readable object" {
    // Parts other than the last must meet the store's 5 MiB minimum.
    @memset(&multipart_a, 0xa5);
    @memset(&multipart_b, 0x5a);
    @memset(&multipart_tail, 0xe7);

    var s3 = try ltx_s3.S3Client.init(
        std.testing.allocator,
        std.testing.io,
        .{
            .host = minio_host,
            .port = minio_port,
            .bucket = "ltx-gate",
            .access_key = minio_root_user,
            .secret_key = minio_root_password,
            .prefix = "replica",
            .clock = .{
                .context = &plain_clock_context,
                .now_ms_fn = TestClock.now_ms,
            },
        },
        &plain_send_workspace,
    );
    defer s3.deinit();

    const identity = ltx.FileIdentity{
        .min_txid = ltx.TXID.init(7),
        .max_txid = ltx.TXID.init(9),
    };
    try s3.begin_multipart(0, identity, 6000);
    try s3.put_part(1, &multipart_a);
    try s3.put_part(2, &multipart_b);
    try s3.put_part(3, &multipart_tail);
    try s3.complete_multipart();
    try std.testing.expect(s3.multipart == null);

    const client = s3.client();
    const stored = try client.read_all(
        object_info(identity, multipart_recv.len),
        &multipart_recv,
    );
    try std.testing.expectEqual(@as(usize, multipart_recv.len), stored.len);
    try std.testing.expectEqualSlices(u8, &multipart_a, stored[0..multipart_part_bytes]);
    try std.testing.expectEqualSlices(u8, &multipart_b, stored[multipart_part_bytes..][0..multipart_part_bytes]);
    try std.testing.expectEqualSlices(u8, &multipart_tail, stored[2 * multipart_part_bytes ..]);
    try client.delete(&.{.{
        .level = 0,
        .min_txid = identity.min_txid,
        .max_txid = identity.max_txid,
        .size_bytes = 0,
    }});
}

test "failed multipart abort preserves cleanup state and blocks writes" {
    var send_workspace: [1024]u8 = undefined;
    var s3 = try init_plain_s3(&send_workspace);
    const working_port = s3.config.port;
    defer {
        s3.config.port = working_port;
        s3.deinit();
    }
    try s3.ensure_bucket();
    const identity = ltx.FileIdentity{
        .min_txid = ltx.TXID.init(38),
        .max_txid = ltx.TXID.init(38),
    };
    try s3.begin_multipart(0, identity, 1_233_000);

    // Force the cleanup request onto an unused endpoint after initiation.
    s3.config.port = minio_port + 1;
    try std.testing.expectError(error.StorageFailure, s3.abort_multipart());
    try std.testing.expect(s3.multipart != null);
    try std.testing.expectError(
        error.InvalidState,
        s3.client().begin_write(0, identity, 1_233_001),
    );

    // The retained upload identity makes a later cleanup retry possible.
    s3.config.port = working_port;
    try s3.abort_multipart();
    try std.testing.expect(s3.multipart == null);
}

test "write session publishes a small stream with one PUT at finish" {
    var send_workspace: [64]u8 = undefined;
    var s3 = try init_plain_s3(&send_workspace);
    defer s3.deinit();
    try s3.ensure_bucket();

    const client = s3.client();
    try std.testing.expect(client.supports_write_sessions());
    const identity = ltx.FileIdentity{
        .min_txid = ltx.TXID.init(40),
        .max_txid = ltx.TXID.init(40),
    };
    try delete_identity(client, identity);
    defer delete_identity(client, identity) catch {};

    var session = try client.begin_write(0, identity, 1_234_000);
    try session.writer().write_all("transactional ");
    try session.writer().write_all("small object");
    try std.testing.expect(s3.multipart == null);
    var received: [64]u8 = undefined;
    try std.testing.expectError(
        error.ObjectNotFound,
        client.read_all(object_info(identity, 1), &received),
    );

    try session.finish();
    try std.testing.expectEqual(
        ltx_object.WriteSessionState.final,
        session.current_state(),
    );
    try std.testing.expect(s3.multipart == null);
    try std.testing.expectEqualStrings(
        "transactional small object",
        try client.read_all(
            object_info(identity, "transactional small object".len),
            &received,
        ),
    );
}

test "write session automatically publishes more than two multipart parts" {
    @memset(&multipart_a, 0xa5);
    @memset(&multipart_b, 0x5a);
    @memset(&multipart_tail, 0xe7);

    var s3 = try init_plain_s3(&automatic_send_workspace);
    defer s3.deinit();
    try s3.ensure_bucket();
    const client = s3.client();
    const identity = ltx.FileIdentity{
        .min_txid = ltx.TXID.init(41),
        .max_txid = ltx.TXID.init(43),
    };
    try delete_identity(client, identity);
    defer delete_identity(client, identity) catch {};

    var session = try client.begin_write(0, identity, 1_234_123);
    try session.writer().write_all(&multipart_a);
    try std.testing.expect(s3.multipart == null);
    try session.writer().write_all(&multipart_b);
    try std.testing.expectEqual(@as(u32, 1), s3.multipart.?.part_count);
    try session.writer().write_all(&multipart_tail);
    try std.testing.expectEqual(@as(u32, 2), s3.multipart.?.part_count);
    try std.testing.expectError(
        error.ObjectNotFound,
        client.read_all(object_info(identity, multipart_recv.len), &multipart_recv),
    );

    try session.finish();
    try std.testing.expect(s3.multipart == null);
    const stored = try client.read_all(
        object_info(identity, multipart_recv.len),
        &multipart_recv,
    );
    try std.testing.expectEqual(@as(usize, multipart_recv.len), stored.len);
    try std.testing.expectEqualSlices(u8, &multipart_a, stored[0..multipart_part_bytes]);
    try std.testing.expectEqualSlices(
        u8,
        &multipart_b,
        stored[multipart_part_bytes..][0..multipart_part_bytes],
    );
    try std.testing.expectEqualSlices(
        u8,
        &multipart_tail,
        stored[2 * multipart_part_bytes ..],
    );
}

test "write session abort removes automatic multipart private state" {
    @memset(&multipart_a, 0x3c);
    @memset(&multipart_tail, 0xc3);

    var s3 = try init_plain_s3(&automatic_send_workspace);
    defer s3.deinit();
    try s3.ensure_bucket();
    const client = s3.client();
    const identity = ltx.FileIdentity{
        .min_txid = ltx.TXID.init(44),
        .max_txid = ltx.TXID.init(45),
    };
    try delete_identity(client, identity);

    var session = try client.begin_write(0, identity, 1_234_456);
    try session.writer().write_all(&multipart_a);
    try session.writer().write_all(&multipart_tail);
    try std.testing.expectEqual(@as(u32, 1), s3.multipart.?.part_count);
    session.abort();

    try std.testing.expectEqual(
        ltx_object.WriteSessionState.final,
        session.current_state(),
    );
    try std.testing.expect(s3.multipart == null);
    try std.testing.expectError(
        error.ObjectNotFound,
        client.read_all(object_info(identity, multipart_recv.len), &multipart_recv),
    );
}

test "failed automatic multipart abort can be retried through the client" {
    @memset(&multipart_a, 0x6d);
    @memset(&multipart_tail, 0xd6);

    var s3 = try init_plain_s3(&automatic_send_workspace);
    const working_port = s3.config.port;
    defer {
        s3.config.port = working_port;
        s3.deinit();
    }
    try s3.ensure_bucket();
    const client = s3.client();
    const identity = ltx.FileIdentity{
        .min_txid = ltx.TXID.init(49),
        .max_txid = ltx.TXID.init(50),
    };
    try delete_identity(client, identity);

    var session = try client.begin_write(0, identity, 1_234_654);
    try session.writer().write_all(&multipart_a);
    try session.writer().write_all(&multipart_tail);
    try std.testing.expectEqual(@as(u32, 1), s3.multipart.?.part_count);

    s3.config.port = minio_port + 1;
    session.abort();
    try std.testing.expect(s3.write_session == null);
    try std.testing.expect(s3.multipart != null);

    s3.config.port = working_port;
    try s3.abort_multipart();
    try std.testing.expect(s3.multipart == null);
}

test "write sessions and manual multipart uploads are mutually exclusive" {
    var send_workspace: [1024]u8 = undefined;
    var s3 = try init_plain_s3(&send_workspace);
    defer s3.deinit();
    try s3.ensure_bucket();
    const client = s3.client();
    const identity = ltx.FileIdentity{
        .min_txid = ltx.TXID.init(46),
        .max_txid = ltx.TXID.init(46),
    };
    try delete_identity(client, identity);

    try s3.begin_multipart(0, identity, 1_234_789);
    try std.testing.expectError(
        error.InvalidState,
        client.begin_write(0, identity, 1_234_789),
    );
    try std.testing.expectError(
        error.InvalidState,
        client.write(0, identity, 1_234_789, "conflict"),
    );
    try s3.abort_multipart();

    var session = try client.begin_write(0, identity, 1_234_789);
    try std.testing.expectError(
        error.InvalidState,
        s3.begin_multipart(0, identity, 1_234_789),
    );
    try std.testing.expectError(error.InvalidState, s3.put_part(1, "conflict"));
    try std.testing.expectError(error.InvalidState, s3.complete_multipart());
    try std.testing.expectError(error.InvalidState, s3.abort_multipart());
    try std.testing.expectError(
        error.InvalidState,
        s3.put_if_absent(0, identity, 1_234_789, "conflict"),
    );
    session.abort();

    // Once another part follows, the preceding part is non-final and must
    // meet S3's minimum part size.
    try s3.begin_multipart(0, identity, 1_234_789);
    try s3.put_part(1, "short");
    try std.testing.expectError(error.InvalidState, s3.put_part(2, "tail"));
    try s3.abort_multipart();
}

test "write session capacity failure poisons and cleans private state" {
    var send_workspace: [1024]u8 = undefined;
    var s3 = try init_plain_s3(&send_workspace);
    defer s3.deinit();
    try s3.ensure_bucket();
    const client = s3.client();
    const identity = ltx.FileIdentity{
        .min_txid = ltx.TXID.init(47),
        .max_txid = ltx.TXID.init(47),
    };
    try delete_identity(client, identity);

    var session = try client.begin_write(0, identity, 1_235_000);
    const full_buffer: [1024]u8 = @splat(0x5a);
    try session.writer().write_all(&full_buffer);
    try std.testing.expectError(
        error.OutputFailure,
        session.writer().write_all("x"),
    );
    try std.testing.expectEqual(
        ltx_object.WriteSessionState.failed,
        session.current_state(),
    );
    try std.testing.expect(s3.multipart == null);
    try std.testing.expectError(error.InvalidState, session.finish());
    try std.testing.expectError(
        error.OutputFailure,
        session.writer().write_all("late"),
    );
    var received: [1]u8 = undefined;
    try std.testing.expectError(
        error.ObjectNotFound,
        client.read_all(object_info(identity, received.len), &received),
    );

    var replacement = try client.begin_write(0, identity, 1_235_001);
    replacement.abort();
}

const RetryProbe = struct {
    calls: u32 = 0,
    fn next(context: *anyopaque, attempt: u32, cause: ltx_s3.RetryCause) ?u64 {
        _ = attempt;
        const self: *RetryProbe = @ptrCast(@alignCast(context));
        self.calls += 1;
        return switch (cause) {
            .transport => 5,
            .status => 25,
        };
    }

    fn sleep(_: *anyopaque, _: u64) ltx_s3.Error!void {}
};

test "a configured retry policy is not consulted on success" {
    var probe = RetryProbe{};
    var s3 = try ltx_s3.S3Client.init(
        std.testing.allocator,
        std.testing.io,
        .{
            .host = minio_host,
            .port = minio_port,
            .bucket = "ltx-gate",
            .access_key = minio_root_user,
            .secret_key = minio_root_password,
            .prefix = "replica",
            .clock = .{
                .context = &plain_clock_context,
                .now_ms_fn = TestClock.now_ms,
            },
            .retry = .{
                .context = &probe,
                .next_delay_ms_fn = RetryProbe.next,
                .sleep_ms_fn = RetryProbe.sleep,
                .max_attempts = 3,
            },
        },
        &plain_send_workspace,
    );
    defer s3.deinit();
    const client = s3.client();
    const identity = ltx.FileIdentity{
        .min_txid = ltx.TXID.init(31),
        .max_txid = ltx.TXID.init(31),
    };
    try client.write(0, identity, 8000, "retry-probe");
    var storage: [64]u8 = undefined;
    try std.testing.expectEqualStrings(
        "retry-probe",
        try client.read_all(object_info(identity, "retry-probe".len), &storage),
    );
    try client.delete(&.{.{
        .level = 0,
        .min_txid = identity.min_txid,
        .max_txid = identity.max_txid,
        .size_bytes = 0,
    }});
    try std.testing.expectEqual(@as(u32, 0), probe.calls);
}

test "etag replace renews only against the observed generation" {
    var s3 = try ltx_s3.S3Client.init(
        std.testing.allocator,
        std.testing.io,
        .{
            .host = minio_host,
            .port = minio_port,
            .bucket = "ltx-gate",
            .access_key = minio_root_user,
            .secret_key = minio_root_password,
            .prefix = "replica",
            .clock = .{
                .context = &plain_clock_context,
                .now_ms_fn = TestClock.now_ms,
            },
        },
        &plain_send_workspace,
    );
    defer s3.deinit();
    const client = s3.client();

    const identity = ltx.FileIdentity{
        .min_txid = ltx.TXID.init(21),
        .max_txid = ltx.TXID.init(21),
    };
    var storage: [64]u8 = undefined;
    try std.testing.expectError(
        error.ObjectNotFound,
        s3.object_etag(0, identity),
    );

    // Claim, read the generation, renew against it, then lose to a shift.
    try s3.put_if_absent(0, identity, 7000, "first");
    // ETag slices live only until the next request, so keep copies.
    var etag_one: [128]u8 = @splat(0);
    {
        const live = try s3.object_etag(0, identity);
        try std.testing.expect(live.len <= etag_one.len);
        @memcpy(etag_one[0..live.len], live);
    }
    try s3.put_if_match(0, identity, 7100, "second", etag_one[0..etag_len(&etag_one)]);
    try std.testing.expectEqualStrings(
        "second",
        try client.read_all(object_info(identity, "second".len), &storage),
    );

    var etag_two: [128]u8 = @splat(0);
    {
        const live = try s3.object_etag(0, identity);
        try std.testing.expect(live.len <= etag_two.len);
        @memcpy(etag_two[0..live.len], live);
    }
    // A contender renews between our read and our write.
    try s3.put_if_match(0, identity, 7200, "contender", etag_two[0..etag_len(&etag_two)]);
    try std.testing.expectError(
        error.ETagMismatch,
        s3.put_if_match(0, identity, 7300, "stale-writer", etag_one[0..etag_len(&etag_one)]),
    );
    try std.testing.expectError(
        error.ETagMismatch,
        s3.put_if_match(0, identity, 7300, "stale-writer", etag_two[0..etag_len(&etag_two)]),
    );
    try std.testing.expectEqualStrings(
        "contender",
        try client.read_all(object_info(identity, "contender".len), &storage),
    );
    try client.delete(&.{.{
        .level = 0,
        .min_txid = identity.min_txid,
        .max_txid = identity.max_txid,
        .size_bytes = 0,
    }});
}

/// The ETag copy keeps its length in a sentinel-free fixed buffer by
/// tracking the quoted length explicitly.
fn etag_len(buffer: *const [128]u8) usize {
    var index: usize = 0;
    while (index < buffer.len and buffer[index] != 0) : (index += 1) {}
    return index;
}

test "virtual-host addressing serves the same objects" {
    if (s3_options.minio_vh_port == 0) {
        return error.SkipZigTest;
    }
    var s3 = try ltx_s3.S3Client.init(
        std.testing.allocator,
        std.testing.io,
        .{
            .host = "localhost",
            .port = s3_options.minio_vh_port,
            .bucket = "ltx-gate-vh",
            .access_key = minio_root_user,
            .secret_key = minio_root_password,
            .prefix = "replica",
            .virtual_host = true,
            .clock = .{
                .context = &plain_clock_context,
                .now_ms_fn = TestClock.now_ms,
            },
        },
        &plain_send_workspace,
    );
    defer s3.deinit();
    try s3.ensure_bucket();
    try ltx_object.run_conformance(s3.client());
}
