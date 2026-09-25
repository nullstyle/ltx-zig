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

/// What an observer saw of one attempt.
const ObservedAttempt = struct {
    method: std.http.Method = .GET,
    attempt: u32 = 0,
    reused: bool = false,
    idle_ms: u64 = 0,
    /// `stage_fn` calls while the attempt ran.
    stage_calls: u32 = 0,
    stage: ltx_s3.Stage = .connect,
    status: u16 = 0,
    s3_code: [64]u8 = undefined,
    s3_code_len: usize = 0,
    failure: ?ltx_s3.ConditionalWriteError = null,
    cause: ?anyerror = null,
    elapsed_ms: u64 = 0,
    will_retry: bool = false,

    fn code(self: *const ObservedAttempt) []const u8 {
        return self.s3_code[0..self.s3_code_len];
    }
};

/// An observer that keeps every attempt it sees.
const ObserverProbe = struct {
    seen: [8]ObservedAttempt = @splat(.{}),
    began: usize = 0,
    ended: usize = 0,

    fn observer(self: *ObserverProbe) ltx_s3.Observer {
        return .{ .context = self, .begin_fn = begin, .stage_fn = stage, .end_fn = end };
    }

    fn begin(context: *anyopaque, attempt: *const ltx_s3.Attempt) void {
        const self: *ObserverProbe = @ptrCast(@alignCast(context));
        self.seen[self.began] = .{ .method = attempt.method, .attempt = attempt.attempt, .reused = attempt.reused, .idle_ms = attempt.idle_ms };
        self.began += 1;
    }

    fn stage(context: *anyopaque, _: ltx_s3.Stage) void {
        const self: *ObserverProbe = @ptrCast(@alignCast(context));
        self.seen[self.began - 1].stage_calls += 1;
    }

    fn end(context: *anyopaque, info: *const ltx_s3.AttemptEnd) void {
        const self: *ObserverProbe = @ptrCast(@alignCast(context));
        const entry = &self.seen[self.ended];
        entry.stage = info.stage;
        entry.status = info.status;
        @memcpy(entry.s3_code[0..info.s3_code.len], info.s3_code);
        entry.s3_code_len = info.s3_code.len;
        entry.failure = info.failure;
        entry.cause = info.cause;
        entry.elapsed_ms = info.elapsed_ms;
        entry.will_retry = info.will_retry;
        self.ended += 1;
    }
};

/// A PUT answered 400 IncompleteBody on a connection the server keeps
/// open, and then a request that must come on a new connection: the
/// client closed the first one (MinIO closes a connection after a PUT's
/// error answer without saying so).
fn serve_put_error_then_head(server: *std.Io.net.Server) anyerror!void {
    {
        var stream = try server.accept(std.testing.io);
        defer stream.close(std.testing.io);
        var read_buffer: [8192]u8 = undefined;
        var write_buffer: [4096]u8 = undefined;
        var body_buffer: [4096]u8 = undefined;
        var stream_reader = stream.reader(std.testing.io, &read_buffer);
        var stream_writer = stream.writer(std.testing.io, &write_buffer);
        var http_server = std.http.Server.init(&stream_reader.interface, &stream_writer.interface);
        var request = try http_server.receiveHead();
        if (request.head.method != .PUT) return error.TestUnexpectedResult;
        const body_reader = try request.readerExpectContinue(&body_buffer);
        _ = try body_reader.discardRemaining();
        try request.respond(
            "<?xml version=\"1.0\"?><Error><Code>IncompleteBody</Code><Message>You did not provide the number of bytes specified by the Content-Length HTTP header.</Message></Error>",
            .{ .status = .bad_request, .keep_alive = true },
        );
        if (http_server.receiveHead()) |_| return error.TestUnexpectedResult else |_| {}
    }
    var stream = try server.accept(std.testing.io);
    defer stream.close(std.testing.io);
    var read_buffer: [8192]u8 = undefined;
    var write_buffer: [4096]u8 = undefined;
    var stream_reader = stream.reader(std.testing.io, &read_buffer);
    var stream_writer = stream.writer(std.testing.io, &write_buffer);
    var http_server = std.http.Server.init(&stream_reader.interface, &stream_writer.interface);
    var request = try http_server.receiveHead();
    if (request.head.method != .HEAD) return error.TestUnexpectedResult;
    try request.respond("", .{ .status = .not_found, .keep_alive = false });
}

test "scripted error answers report their S3 code and close a PUT's connection" {
    var address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var server = try address.listen(std.testing.io, .{});
    defer server.deinit(std.testing.io);
    var server_task = std.testing.io.async(serve_put_error_then_head, .{&server});
    defer _ = server_task.cancel(std.testing.io) catch {};

    var probe: ObserverProbe = .{};
    var send_workspace: [64]u8 = undefined;
    var s3 = try ltx_s3.S3Client.init(std.testing.allocator, std.testing.io, .{
        .host = "127.0.0.1",
        .port = server.socket.address.getPort(),
        .bucket = "scripted-code",
        .access_key = "test-access",
        .secret_key = "test-secret",
        .clock = .{ .context = &plain_clock_context, .now_ms_fn = TestClock.now_ms },
        .observer = probe.observer(),
    }, &send_workspace);
    defer s3.deinit();
    const identity: ltx.FileIdentity = .{ .min_txid = .init(5), .max_txid = .init(5) };
    try std.testing.expectError(error.StorageFailure, s3.client().write(0, identity, 1, "payload"));
    try std.testing.expectEqual(@as(usize, 0), s3.http.connection_pool.free_len);
    try std.testing.expectError(error.ObjectNotFound, s3.object_etag(0, identity));
    try server_task.await(std.testing.io);

    try std.testing.expectEqual(@as(usize, 2), probe.ended);
    const put = probe.seen[0];
    try std.testing.expectEqual(std.http.Method.PUT, put.method);
    try std.testing.expectEqual(ltx_s3.Stage.status, put.stage);
    try std.testing.expectEqual(@as(u16, 400), put.status);
    try std.testing.expectEqualStrings("IncompleteBody", put.code());
    try std.testing.expectEqual(@as(?ltx_s3.ConditionalWriteError, null), put.failure);
    const head = probe.seen[1];
    try std.testing.expectEqual(std.http.Method.HEAD, head.method);
    try std.testing.expect(!head.reused);
    try std.testing.expectEqual(@as(u16, 404), head.status);
    try std.testing.expectEqualStrings("", head.code());
}

/// One step of a scripted keep-alive server.
const Scripted = union(enum) {
    /// Answer with this status, body and headers.
    answer: struct {
        status: std.http.Status,
        body: []const u8 = "",
        headers: []const std.http.Header = &.{},
        keep_alive: bool = true,
    },
    /// Read the request, then close the connection without an answer.
    drop,
};

/// Serves `script` in order, one request a step, on as many connections
/// as the client opens; a connection stays open until the client closes
/// it, a `drop` closes it, or an answer does not keep it alive.
/// `connections[i]` counts the requests the i-th connection carried.
fn serve_script(server: *std.Io.net.Server, script: []const Scripted, connections: []u32) anyerror!void {
    var step: usize = 0;
    var index: usize = 0;
    while (step < script.len) : (index += 1) {
        var stream = try server.accept(std.testing.io);
        defer stream.close(std.testing.io);
        var read_buffer: [8192]u8 = undefined;
        var write_buffer: [4096]u8 = undefined;
        var body_buffer: [4096]u8 = undefined;
        var stream_reader = stream.reader(std.testing.io, &read_buffer);
        var stream_writer = stream.writer(std.testing.io, &write_buffer);
        var http_server = std.http.Server.init(&stream_reader.interface, &stream_writer.interface);
        while (step < script.len) {
            // The client closed this connection: its next request comes
            // on another.
            var request = http_server.receiveHead() catch break;
            if (request.head.method.requestHasBody()) {
                const body_reader = try request.readerExpectContinue(&body_buffer);
                _ = try body_reader.discardRemaining();
            }
            connections[index] += 1;
            const current = script[step];
            step += 1;
            switch (current) {
                .answer => |answer| {
                    try request.respond(answer.body, .{
                        .status = answer.status,
                        .keep_alive = answer.keep_alive,
                        .extra_headers = answer.headers,
                    });
                    if (!answer.keep_alive) break;
                },
                .drop => break,
            }
        }
    }
}

/// A scripted server on a loopback port whose first connect is refused:
/// the retry policy's first pause opens the listener and starts
/// `serve_script` on it. Every pause after it returns at once.
const Relisten = struct {
    port: u16,
    script: []const Scripted,
    connections: [8]u32 = @splat(0),
    server: std.Io.net.Server = undefined,
    task: ?std.Io.Future(anyerror!void) = null,
    /// The policy's delay calls.
    calls: u32 = 0,

    /// A port whose listener is closed.
    fn init(script: []const Scripted) !Relisten {
        var address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
        var probe_server = try address.listen(std.testing.io, .{});
        defer probe_server.deinit(std.testing.io);
        return .{ .port = probe_server.socket.address.getPort(), .script = script };
    }

    fn deinit(self: *Relisten) void {
        if (self.task) |*task| {
            _ = task.cancel(std.testing.io) catch {};
            self.server.deinit(std.testing.io);
        }
    }

    fn policy(self: *Relisten, max_attempts: u32) ltx_s3.RetryPolicy {
        return .{ .context = self, .next_delay_ms_fn = next, .sleep_ms_fn = sleep, .max_attempts = max_attempts };
    }

    fn next(context: *anyopaque, _: u32, _: ltx_s3.RetryCause) ?u64 {
        const self: *Relisten = @ptrCast(@alignCast(context));
        self.calls += 1;
        return 1;
    }

    fn sleep(context: *anyopaque, _: u64) ltx_s3.Error!void {
        const self: *Relisten = @ptrCast(@alignCast(context));
        if (self.task != null) return;
        var address = std.Io.net.IpAddress.parseIp4("127.0.0.1", self.port) catch return error.StorageFailure;
        self.server = address.listen(std.testing.io, .{ .reuse_address = true }) catch return error.StorageFailure;
        self.task = std.testing.io.async(serve_script, .{ &self.server, self.script, &self.connections });
    }

    /// A client of the scripted server with this policy and `observer`.
    fn client(self: *Relisten, send_workspace: []u8, max_attempts: u32, observer: ?ltx_s3.Observer) !ltx_s3.S3Client {
        return ltx_s3.S3Client.init(std.testing.allocator, std.testing.io, .{
            .host = "127.0.0.1",
            .port = self.port,
            .bucket = "scripted-retry",
            .access_key = "test-access",
            .secret_key = "test-secret",
            .clock = .{ .context = &plain_clock_context, .now_ms_fn = TestClock.now_ms },
            .retry = self.policy(max_attempts),
            .observer = observer,
        }, send_workspace);
    }
};

test "scripted observer sees every attempt's stage" {
    // The first connect is refused; the second attempt's connection closes
    // without an answer; the third is answered 503 SlowDown, the fourth
    // 206.
    const script = [_]Scripted{
        .drop,
        .{ .answer = .{ .status = .service_unavailable, .body = "<Error><Code>SlowDown</Code><Message>Please reduce your request rate.</Message></Error>", .keep_alive = false } },
        .{ .answer = .{ .status = .partial_content, .body = "abc", .headers = &valid_range_headers, .keep_alive = false } },
    };
    var relisten = try Relisten.init(&script);
    defer relisten.deinit();
    var probe: ObserverProbe = .{};
    var send_workspace: [64]u8 = undefined;
    var s3 = try relisten.client(&send_workspace, 5, probe.observer());
    defer s3.deinit();
    var destination: [3]u8 = undefined;
    _ = try s3.client().read_range(
        object_info(.{ .min_txid = .init(1), .max_txid = .init(1) }, 6),
        0,
        &destination,
    );
    try std.testing.expectEqualStrings("abc", &destination);
    try relisten.task.?.await(std.testing.io);

    try std.testing.expectEqual(@as(usize, 4), probe.ended);
    const expected_stages = [_]ltx_s3.Stage{ .connect, .receive_head, .status, .status };
    const expected_statuses = [_]u16{ 0, 0, 503, 206 };
    for (probe.seen[0..4], 0..) |seen, index| {
        try std.testing.expectEqual(@as(u32, @intCast(index + 1)), seen.attempt);
        try std.testing.expectEqual(expected_stages[index], seen.stage);
        try std.testing.expectEqual(expected_statuses[index], seen.status);
        try std.testing.expectEqual(index < 3, seen.will_retry);
        try std.testing.expect(!seen.reused);
    }
    try std.testing.expectEqual(error.StorageFailure, probe.seen[0].failure.?);
    try std.testing.expect(probe.seen[0].cause != null);
    try std.testing.expectEqual(@as(u32, 0), probe.seen[0].stage_calls);
    try std.testing.expectEqual(error.StorageFailure, probe.seen[1].failure.?);
    try std.testing.expect(probe.seen[1].cause != null);
    // Send, then the wait for the head.
    try std.testing.expectEqual(@as(u32, 2), probe.seen[1].stage_calls);
    try std.testing.expectEqualStrings("SlowDown", probe.seen[2].code());
    try std.testing.expectEqual(@as(?ltx_s3.ConditionalWriteError, null), probe.seen[2].failure);
    // Send, head, headers, status, the body, and status again.
    try std.testing.expectEqual(@as(u32, 6), probe.seen[3].stage_calls);
    try std.testing.expect(probe.seen[3].elapsed_ms >= probe.seen[0].elapsed_ms);
}

const not_found_answer: Scripted = .{ .answer = .{ .status = .not_found } };

test "scripted idle pooled connections are dropped before reuse" {
    var address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var server = try address.listen(std.testing.io, .{});
    defer server.deinit(std.testing.io);
    const script: [3]Scripted = @splat(not_found_answer);
    var connections: [2]u32 = @splat(0);
    var server_task = std.testing.io.async(serve_script, .{ &server, &script, &connections });
    defer _ = server_task.cancel(std.testing.io) catch {};

    const now = std.Io.Timestamp.now(std.testing.io, .real);
    var clock = MutableClock{ .value_ms = @intCast(@divTrunc(now.nanoseconds, std.time.ns_per_ms)) };
    var probe: ObserverProbe = .{};
    var send_workspace: [64]u8 = undefined;
    var s3 = try ltx_s3.S3Client.init(std.testing.allocator, std.testing.io, .{
        .host = "127.0.0.1",
        .port = server.socket.address.getPort(),
        .bucket = "scripted-idle",
        .access_key = "test-access",
        .secret_key = "test-secret",
        .clock = .{ .context = &clock, .now_ms_fn = MutableClock.now_ms },
        .max_idle_reuse_ms = 1000,
        .observer = probe.observer(),
    }, &send_workspace);
    defer s3.deinit();
    const identity: ltx.FileIdentity = .{ .min_txid = .init(1), .max_txid = .init(1) };
    // A HEAD leaves its connection in the pool; one 500 ms later reuses it;
    // one 2 s after that finds it idle past the limit and opens another.
    try std.testing.expectError(error.ObjectNotFound, s3.object_etag(0, identity));
    clock.value_ms += 500;
    try std.testing.expectError(error.ObjectNotFound, s3.object_etag(0, identity));
    clock.value_ms += 2000;
    try std.testing.expectError(error.ObjectNotFound, s3.object_etag(0, identity));
    try server_task.await(std.testing.io);
    try std.testing.expectEqualSlices(u32, &.{ 2, 1 }, &connections);
    try std.testing.expect(probe.seen[1].reused);
    try std.testing.expectEqual(@as(u64, 500), probe.seen[1].idle_ms);
    try std.testing.expect(!probe.seen[2].reused);
    try std.testing.expectEqual(@as(u64, 2000), probe.seen[2].idle_ms);
}

test "scripted idle time is measured on the steady clock, not the wall clock" {
    // The wall clock signs; it can step back (NTP, an operator), and a
    // connection idle past the limit then looked fresh and was sent on.
    var address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var server = try address.listen(std.testing.io, .{});
    defer server.deinit(std.testing.io);
    const script: [3]Scripted = @splat(not_found_answer);
    var connections: [2]u32 = @splat(0);
    var server_task = std.testing.io.async(serve_script, .{ &server, &script, &connections });
    defer _ = server_task.cancel(std.testing.io) catch {};

    const now = std.Io.Timestamp.now(std.testing.io, .real);
    var wall = MutableClock{ .value_ms = @intCast(@divTrunc(now.nanoseconds, std.time.ns_per_ms)) };
    var steady = MutableClock{ .value_ms = 1000 };
    var probe: ObserverProbe = .{};
    var send_workspace: [64]u8 = undefined;
    var s3 = try ltx_s3.S3Client.init(std.testing.allocator, std.testing.io, .{
        .host = "127.0.0.1",
        .port = server.socket.address.getPort(),
        .bucket = "scripted-steady",
        .access_key = "test-access",
        .secret_key = "test-secret",
        .clock = .{ .context = &wall, .now_ms_fn = MutableClock.now_ms },
        .steady_clock = .{ .context = &steady, .now_ms_fn = MutableClock.now_ms },
        .max_idle_reuse_ms = 1000,
        .observer = probe.observer(),
    }, &send_workspace);
    defer s3.deinit();
    const identity: ltx.FileIdentity = .{ .min_txid = .init(1), .max_txid = .init(1) };
    // A HEAD leaves its connection in the pool. 500 ms later, with the wall
    // clock stepped forward 5 s, the next one reuses it; 2 s after that,
    // with the wall clock stepped back 3 s, the next one opens another.
    try std.testing.expectError(error.ObjectNotFound, s3.object_etag(0, identity));
    steady.value_ms += 500;
    wall.value_ms += 5000;
    try std.testing.expectError(error.ObjectNotFound, s3.object_etag(0, identity));
    steady.value_ms += 2000;
    wall.value_ms -= 3000;
    try std.testing.expectError(error.ObjectNotFound, s3.object_etag(0, identity));
    try server_task.await(std.testing.io);
    try std.testing.expectEqualSlices(u32, &.{ 2, 1 }, &connections);
    try std.testing.expect(probe.seen[1].reused);
    try std.testing.expectEqual(@as(u64, 500), probe.seen[1].idle_ms);
    try std.testing.expect(!probe.seen[2].reused);
    try std.testing.expectEqual(@as(u64, 2000), probe.seen[2].idle_ms);
}

/// Accepts two connections and closes them: a store that restarted.
fn close_two_connections(server: *std.Io.net.Server) anyerror!void {
    var first = try server.accept(std.testing.io);
    var second = try server.accept(std.testing.io);
    first.close(std.testing.io);
    second.close(std.testing.io);
}

test "scripted transport failure drops the pool before the retry" {
    // A store that restarts stales every pooled connection, whatever its
    // age: the retry must not take the next stale one.
    var address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var server = try address.listen(std.testing.io, .{});
    defer server.deinit(std.testing.io);
    const port = server.socket.address.getPort();
    var retry_probe = RetryProbe{};
    var probe: ObserverProbe = .{};
    var send_workspace: [64]u8 = undefined;
    var s3 = try ltx_s3.S3Client.init(std.testing.allocator, std.testing.io, .{
        .host = "127.0.0.1",
        .port = port,
        .bucket = "scripted-stale",
        .access_key = "test-access",
        .secret_key = "test-secret",
        .clock = .{ .context = &plain_clock_context, .now_ms_fn = TestClock.now_ms },
        .retry = .{ .context = &retry_probe, .next_delay_ms_fn = RetryProbe.next, .sleep_ms_fn = RetryProbe.sleep, .max_attempts = 4 },
        .observer = probe.observer(),
    }, &send_workspace);
    defer s3.deinit();

    // Two open connections in the pool, which the server then closes.
    var closing_task = std.testing.io.async(close_two_connections, .{&server});
    defer _ = closing_task.cancel(std.testing.io) catch {};
    const host = try std.Io.net.HostName.init("127.0.0.1");
    const first = try s3.http.connect(host, port, .plain);
    const second = try s3.http.connect(host, port, .plain);
    s3.http.connection_pool.release(first, std.testing.io);
    s3.http.connection_pool.release(second, std.testing.io);
    try closing_task.await(std.testing.io);
    try std.testing.expectEqual(@as(usize, 2), s3.http.connection_pool.free_len);

    const script = [_]Scripted{not_found_answer};
    var connections: [1]u32 = @splat(0);
    var server_task = std.testing.io.async(serve_script, .{ &server, &script, &connections });
    defer _ = server_task.cancel(std.testing.io) catch {};
    const identity: ltx.FileIdentity = .{ .min_txid = .init(1), .max_txid = .init(1) };
    try std.testing.expectError(error.ObjectNotFound, s3.object_etag(0, identity));
    try server_task.await(std.testing.io);
    // The first attempt met a stale connection; the retry opened a new one.
    try std.testing.expectEqual(@as(u32, 1), retry_probe.calls);
    try std.testing.expectEqual(@as(usize, 2), probe.ended);
    try std.testing.expect(probe.seen[0].reused);
    try std.testing.expect(probe.seen[0].failure != null);
    try std.testing.expect(!probe.seen[1].reused);
}

/// Answers one HEAD 404 on a connection kept alive, then resets it (a close
/// with a zero linger): a store that dropped the connection, whose next
/// request fails while it is sent.
fn answer_then_reset(server: *std.Io.net.Server) anyerror!void {
    var stream = try server.accept(std.testing.io);
    defer stream.close(std.testing.io);
    var read_buffer: [8192]u8 = undefined;
    var write_buffer: [4096]u8 = undefined;
    var stream_reader = stream.reader(std.testing.io, &read_buffer);
    var stream_writer = stream.writer(std.testing.io, &write_buffer);
    var http_server = std.http.Server.init(&stream_reader.interface, &stream_writer.interface);
    var request = try http_server.receiveHead();
    if (request.head.method != .HEAD) return error.TestUnexpectedResult;
    try request.respond("", .{ .status = .not_found, .keep_alive = true });
    const linger: std.c.linger = .{ .onoff = 1, .linger = 0 };
    try std.posix.setsockopt(stream.socket.handle, std.posix.SOL.SOCKET, std.posix.SO.LINGER, std.mem.asBytes(&linger));
}

test "scripted transport failure that is not retried leaves no pooled connection" {
    // A request that failed on its connection was sent into a dead one: a
    // failure while sending left that connection in the pool, and the
    // next request, of another operation, took it and failed the same way.
    var address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var server = try address.listen(std.testing.io, .{});
    defer server.deinit(std.testing.io);
    const port = server.socket.address.getPort();
    var probe: ObserverProbe = .{};
    var send_workspace: [64]u8 = undefined;
    var s3 = try ltx_s3.S3Client.init(std.testing.allocator, std.testing.io, .{
        .host = "127.0.0.1",
        .port = port,
        .bucket = "scripted-dead",
        .access_key = "test-access",
        .secret_key = "test-secret",
        .clock = .{ .context = &plain_clock_context, .now_ms_fn = TestClock.now_ms },
        .observer = probe.observer(),
    }, &send_workspace);
    defer s3.deinit();
    const identity: ltx.FileIdentity = .{ .min_txid = .init(1), .max_txid = .init(1) };

    // The store answers a HEAD, then resets the kept connection. A claim
    // (a conditional PUT, never sent again after it was sent) fails while
    // it is sent on it.
    var reset_task = std.testing.io.async(answer_then_reset, .{&server});
    defer _ = reset_task.cancel(std.testing.io) catch {};
    try std.testing.expectError(error.ObjectNotFound, s3.object_etag(0, identity));
    try reset_task.await(std.testing.io);
    try std.testing.expectEqual(@as(usize, 1), s3.http.connection_pool.free_len);
    try std.testing.expectError(error.PublicationIndeterminate, s3.put_if_absent(0, identity, 1, "claim"));
    try std.testing.expectEqual(ltx_s3.Stage.send, probe.seen[1].stage);
    try std.testing.expect(probe.seen[1].reused);
    try std.testing.expect(!probe.seen[1].will_retry);
    try std.testing.expectEqual(@as(usize, 0), s3.http.connection_pool.free_len);

    // Two pooled connections the store closed: a request that fails on the
    // first, and is not sent again, leaves the second unused too.
    var closing_task = std.testing.io.async(close_two_connections, .{&server});
    defer _ = closing_task.cancel(std.testing.io) catch {};
    const host = try std.Io.net.HostName.init("127.0.0.1");
    const first = try s3.http.connect(host, port, .plain);
    const second = try s3.http.connect(host, port, .plain);
    s3.http.connection_pool.release(first, std.testing.io);
    s3.http.connection_pool.release(second, std.testing.io);
    try closing_task.await(std.testing.io);
    try std.testing.expectEqual(@as(usize, 2), s3.http.connection_pool.free_len);
    try std.testing.expectError(error.StorageFailure, s3.object_etag(0, identity));
    try std.testing.expect(probe.seen[2].reused);
    try std.testing.expectEqual(@as(usize, 0), s3.http.connection_pool.free_len);

    // The next request opens a connection of its own, and is answered.
    const script = [_]Scripted{not_found_answer};
    var connections: [1]u32 = @splat(0);
    var server_task = std.testing.io.async(serve_script, .{ &server, &script, &connections });
    defer _ = server_task.cancel(std.testing.io) catch {};
    try std.testing.expectError(error.ObjectNotFound, s3.object_etag(0, identity));
    try server_task.await(std.testing.io);
    try std.testing.expect(!probe.seen[3].reused);
    try std.testing.expectEqual(@as(usize, 4), probe.ended);
}

fn error_answer(status: std.http.Status, comptime code: []const u8) Scripted {
    return .{ .answer = .{ .status = status, .body = "<Error><Code>" ++ code ++ "</Code><Message>scripted</Message></Error>" } };
}

test "scripted 400 RequestTimeout and IncompleteBody are retried, 501 is not" {
    var address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var server = try address.listen(std.testing.io, .{});
    defer server.deinit(std.testing.io);
    const script = [_]Scripted{
        error_answer(.bad_request, "RequestTimeout"),
        error_answer(.bad_request, "IncompleteBody"),
        .{ .answer = .{ .status = .partial_content, .body = "abc", .headers = &valid_range_headers } },
        error_answer(.not_implemented, "NotImplemented"),
        error_answer(.bad_request, "InvalidArgument"),
    };
    var connections: [4]u32 = @splat(0);
    var server_task = std.testing.io.async(serve_script, .{ &server, &script, &connections });
    defer _ = server_task.cancel(std.testing.io) catch {};
    var retry_probe = RetryProbe{};
    var send_workspace: [64]u8 = undefined;
    var s3 = try ltx_s3.S3Client.init(std.testing.allocator, std.testing.io, .{
        .host = "127.0.0.1",
        .port = server.socket.address.getPort(),
        .bucket = "scripted-transient",
        .access_key = "test-access",
        .secret_key = "test-secret",
        .clock = .{ .context = &plain_clock_context, .now_ms_fn = TestClock.now_ms },
        .retry = .{ .context = &retry_probe, .next_delay_ms_fn = RetryProbe.next, .sleep_ms_fn = RetryProbe.sleep, .max_attempts = 4 },
    }, &send_workspace);
    defer s3.deinit();
    const info = object_info(.{ .min_txid = .init(1), .max_txid = .init(1) }, 6);
    var destination: [3]u8 = undefined;
    _ = try s3.client().read_range(info, 0, &destination);
    try std.testing.expectEqualStrings("abc", &destination);
    try std.testing.expectEqual(@as(u32, 2), retry_probe.calls);
    // 501 and a 400 of another code are not asked about at all.
    try std.testing.expectError(error.StorageFailure, s3.client().read_range(info, 0, &destination));
    try std.testing.expectError(error.StorageFailure, s3.client().read_range(info, 0, &destination));
    try std.testing.expectEqual(@as(u32, 2), retry_probe.calls);
    try server_task.await(std.testing.io);
}

test "scripted conditional PUT is retried after a refused connect or a 429, never after a 5xx or a lost answer" {
    const script = [_]Scripted{
        error_answer(.too_many_requests, "SlowDown"),
        .{ .answer = .{ .status = .ok } },
        error_answer(.service_unavailable, "SlowDown"),
        .drop,
    };
    var relisten = try Relisten.init(&script);
    defer relisten.deinit();
    var send_workspace: [64]u8 = undefined;
    var s3 = try relisten.client(&send_workspace, 5, null);
    defer s3.deinit();
    const identity: ltx.FileIdentity = .{ .min_txid = .init(7), .max_txid = .init(7) };
    // Refused (nothing sent), then 429 (nothing stored), then stored.
    try s3.put_if_absent(0, identity, 1, "claim");
    try std.testing.expectEqual(@as(u32, 2), relisten.calls);
    // A 5xx and a lost answer may hide a write: indeterminate, never sent
    // again, and the policy is not asked.
    try std.testing.expectError(error.PublicationIndeterminate, s3.put_if_absent(0, identity, 2, "claim"));
    try std.testing.expectError(error.PublicationIndeterminate, s3.put_if_absent(0, identity, 3, "claim"));
    try std.testing.expectEqual(@as(u32, 2), relisten.calls);
    try relisten.task.?.await(std.testing.io);
}

/// One page a scripted listing server answers: the continuation token the
/// request must carry (decoded; null on a walk's first page), `key_count`
/// level-0 keys from `first_txid` on, and the page's truncation flag and
/// token (null leaves the token out).
const ScriptedListPage = struct {
    expected_token: ?[]const u8,
    first_txid: u64,
    key_count: u32,
    truncated: bool,
    next_token: ?[]const u8,
};

/// Decodes a query value's `%XX` escapes into `out`.
fn percent_decode(text: []const u8, out: []u8) ![]const u8 {
    var in: usize = 0;
    var len: usize = 0;
    while (in < text.len) : (len += 1) {
        if (len == out.len) return error.TestUnexpectedResult;
        if (text[in] != '%') {
            out[len] = text[in];
            in += 1;
            continue;
        }
        if (in + 3 > text.len) return error.TestUnexpectedResult;
        out[len] = try std.fmt.parseInt(u8, text[in + 1 .. in + 3], 16);
        in += 3;
    }
    return out[0..len];
}

/// The decoded value of query parameter `name`, or null.
fn query_value(target: []const u8, name: []const u8, out: []u8) !?[]const u8 {
    const query_at = std.mem.indexOfScalar(u8, target, '?') orelse return null;
    var pairs = std.mem.splitScalar(u8, target[query_at + 1 ..], '&');
    while (pairs.next()) |pair| {
        const equals = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (!std.mem.eql(u8, pair[0..equals], name)) continue;
        return try percent_decode(pair[equals + 1 ..], out);
    }
    return null;
}

fn serve_scripted_list_pages(
    server: *std.Io.net.Server,
    prefix: []const u8,
    pages: []const ScriptedListPage,
) !void {
    for (pages) |page| {
        var stream = try server.accept(std.testing.io);
        defer stream.close(std.testing.io);
        var read_buffer: [16 * 1024]u8 = undefined;
        var write_buffer: [4096]u8 = undefined;
        var stream_reader = stream.reader(std.testing.io, &read_buffer);
        var stream_writer = stream.writer(std.testing.io, &write_buffer);
        var http_server = std.http.Server.init(
            &stream_reader.interface,
            &stream_writer.interface,
        );
        var request = try http_server.receiveHead();
        const target = request.head.target;
        var token_buffer: [4096]u8 = undefined;
        const token = try query_value(target, "continuation-token", &token_buffer);
        var prefix_buffer: [4096]u8 = undefined;
        const listed_prefix = (try query_value(target, "prefix", &prefix_buffer)) orelse "";
        var expected_prefix_buffer: [4096]u8 = undefined;
        const expected_prefix = try std.fmt.bufPrint(&expected_prefix_buffer, "{s}/0000/", .{prefix});
        const valid_request = request.head.method == .GET and
            std.mem.startsWith(u8, target, "/scripted-list/?") and
            std.mem.eql(u8, listed_prefix, expected_prefix) and
            if (page.expected_token) |expected|
                token != null and std.mem.eql(u8, token.?, expected)
            else
                token == null;

        var body_buffer: [16 * 1024]u8 = undefined;
        var body: std.Io.Writer = .fixed(&body_buffer);
        try body.print("<ListBucketResult><IsTruncated>{s}</IsTruncated>", .{
            if (page.truncated) "true" else "false",
        });
        var index: u32 = 0;
        while (index < page.key_count) : (index += 1) {
            var name: [ltx.file_name_bytes]u8 = undefined;
            const txid = ltx.TXID.init(page.first_txid + index);
            _ = ltx.format_file_name(txid, txid, &name);
            try body.print("<Contents><Key>{s}{s}</Key><Size>7</Size></Contents>", .{ expected_prefix, &name });
        }
        if (page.next_token) |next| {
            try body.print("<NextContinuationToken>{s}</NextContinuationToken>", .{next});
        }
        try body.writeAll("</ListBucketResult>");
        try request.respond(body.buffered(), .{ .status = .ok, .keep_alive = false });
        if (!valid_request) return error.TestUnexpectedResult;
    }
}

/// A client of the scripted listing server under `prefix`.
fn init_scripted_list_s3(port: u16, prefix: []const u8, send_workspace: []u8) !ltx_s3.S3Client {
    return ltx_s3.S3Client.init(
        std.testing.allocator,
        std.testing.io,
        .{
            .host = "127.0.0.1",
            .port = port,
            .bucket = "scripted-list",
            .access_key = "test-access",
            .secret_key = "test-secret",
            .prefix = prefix,
            .clock = .{
                .context = &plain_clock_context,
                .now_ms_fn = TestClock.now_ms,
            },
        },
        send_workspace,
    );
}

/// A prefix of `length` bytes with a slash every 200 (a store's path
/// segments stop at 255 bytes) and a space, a plus and an equals sign,
/// which a query must percent-encode.
fn fill_long_prefix(out: []u8) []const u8 {
    const pattern = "ab c+d=ef";
    for (out, 0..) |*byte, index| {
        byte.* = if ((index + 1) % 200 == 0) '/' else pattern[index % pattern.len];
    }
    return out;
}

/// A continuation token of `length` bytes in the base64 alphabet, which a
/// query must percent-encode (`+`, `/` and `=`).
fn fill_token(out: []u8) []const u8 {
    const alphabet = "AZaz09+/";
    for (out, 0..) |*byte, index| byte.* = alphabet[index % alphabet.len];
    out[out.len - 1] = '=';
    return out;
}

test "scripted listing pages past 16 keys under a 900-byte prefix" {
    var prefix_storage: [900]u8 = undefined;
    const prefix = fill_long_prefix(&prefix_storage);
    var short_storage: [272]u8 = undefined;
    const short_token = fill_token(&short_storage);
    var long_storage: [1400]u8 = undefined;
    const long_token = fill_token(&long_storage);
    var address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var server = try address.listen(std.testing.io, .{});
    defer server.deinit(std.testing.io);
    const pages = [_]ScriptedListPage{
        .{ .expected_token = null, .first_txid = 1, .key_count = 8, .truncated = true, .next_token = short_token },
        .{ .expected_token = short_token, .first_txid = 9, .key_count = 8, .truncated = true, .next_token = long_token },
        .{ .expected_token = long_token, .first_txid = 17, .key_count = 4, .truncated = false, .next_token = null },
    };
    var server_task = std.testing.io.async(
        serve_scripted_list_pages,
        .{ &server, prefix, &pages },
    );
    defer _ = server_task.cancel(std.testing.io) catch {};

    var send_workspace: [64]u8 = undefined;
    var s3 = try init_scripted_list_s3(server.socket.address.getPort(), prefix, &send_workspace);
    defer s3.deinit();
    var infos: [24]ltx.FileInfo = undefined;
    const listed = try s3.client().list(0, ltx.TXID.init(0), &infos);
    try server_task.await(std.testing.io);
    try std.testing.expectEqual(@as(usize, 20), listed.len);
    for (listed, 1..) |info, txid| {
        try std.testing.expectEqual(@as(u64, txid), info.min_txid.value);
    }
}

test "scripted listing page truncated without a token is listed again from the start" {
    var address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var server = try address.listen(std.testing.io, .{});
    defer server.deinit(std.testing.io);
    // The first walk's page has no token: the second walk starts over,
    // and the first walk's keys are not counted twice.
    const pages = [_]ScriptedListPage{
        .{ .expected_token = null, .first_txid = 1, .key_count = 8, .truncated = true, .next_token = null },
        .{ .expected_token = null, .first_txid = 1, .key_count = 8, .truncated = true, .next_token = "next+page=" },
        .{ .expected_token = "next+page=", .first_txid = 9, .key_count = 4, .truncated = false, .next_token = null },
    };
    var server_task = std.testing.io.async(
        serve_scripted_list_pages,
        .{ &server, "relist", &pages },
    );
    defer _ = server_task.cancel(std.testing.io) catch {};

    var send_workspace: [64]u8 = undefined;
    var s3 = try init_scripted_list_s3(server.socket.address.getPort(), "relist", &send_workspace);
    defer s3.deinit();
    var infos: [16]ltx.FileInfo = undefined;
    const listed = try s3.client().list(0, ltx.TXID.init(0), &infos);
    try server_task.await(std.testing.io);
    try std.testing.expectEqual(@as(usize, 12), listed.len);
    try std.testing.expectEqual(@as(u64, 12), listed[11].min_txid.value);
}

test "scripted listing fails after its walks keep losing their token" {
    var address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var server = try address.listen(std.testing.io, .{});
    defer server.deinit(std.testing.io);
    const lost: ScriptedListPage = .{ .expected_token = null, .first_txid = 1, .key_count = 2, .truncated = true, .next_token = null };
    const pages: [ltx_s3.max_listing_restarts + 1]ScriptedListPage = @splat(lost);
    var server_task = std.testing.io.async(
        serve_scripted_list_pages,
        .{ &server, "relist", &pages },
    );
    defer _ = server_task.cancel(std.testing.io) catch {};

    var send_workspace: [64]u8 = undefined;
    var s3 = try init_scripted_list_s3(server.socket.address.getPort(), "relist", &send_workspace);
    defer s3.deinit();
    var infos: [16]ltx.FileInfo = undefined;
    try std.testing.expectError(
        error.StorageFailure,
        s3.client().list(0, ltx.TXID.init(0), &infos),
    );
    try std.testing.expectEqualStrings(
        "a truncated listing page without a continuation token",
        s3.last_parse_failure,
    );
    // Every walk was tried, and no fourth.
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
    try std.testing.expectEqualSlices(u8, &@as([3]u8, @splat(0xcc)), &second);
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
    try std.testing.expectEqualSlices(u8, &@as([3]u8, @splat(0xcc)), output[3..]);
    try std.testing.expectEqualStrings("def", &workspace);

    var late: [3]u8 = @splat(0x5a);
    try std.testing.expectError(error.InputFailure, reader.read(&late));
    try std.testing.expectEqualSlices(u8, &@as([3]u8, @splat(0x5a)), &late);
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

test "objects under a long prefix that needs encoding write, list past 16 keys, read and delete" {
    // MinIO's continuation tokens are the base64 of the last key and a
    // suffix: about 900 bytes under this prefix, where the token workspace
    // once held 256, and the query that carries one and the prefix twice
    // passes 1,024. The prefix's space, plus and equals sign must be
    // encoded alike in the path, the query and the signature. (MinIO on
    // macOS refuses a key whose file path under its data directory passes
    // 1,024 bytes, so a longer prefix fails there.)
    var prefix_storage: [590]u8 = undefined;
    const prefix = fill_long_prefix(&prefix_storage);
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
            .prefix = prefix,
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
    var infos: [24]ltx.FileInfo = undefined;
    for (try client.list(0, ltx.TXID.init(0), &infos)) |stale| {
        try client.delete(&.{stale});
    }
    var txid: u64 = 1;
    while (txid <= 20) : (txid += 1) {
        const identity: ltx.FileIdentity = .{ .min_txid = .init(txid), .max_txid = .init(txid) };
        try client.write(0, identity, @intCast(txid), "encoded");
    }
    defer {
        var cleanup: [24]ltx.FileInfo = undefined;
        if (client.list(0, ltx.TXID.init(0), &cleanup)) |listed| {
            for (listed) |info| client.delete(&.{info}) catch {};
        } else |_| {}
    }
    const listed = try client.list(0, ltx.TXID.init(0), &infos);
    try std.testing.expectEqual(@as(usize, 20), listed.len);
    for (listed, 1..) |info, expected| {
        try std.testing.expectEqual(@as(u64, expected), info.min_txid.value);
    }
    var storage: [16]u8 = undefined;
    try std.testing.expectEqualStrings("encoded", try client.read_all(listed[19], &storage));
    try client.delete(listed);
    try std.testing.expectEqual(@as(usize, 0), (try client.list(0, ltx.TXID.init(0), &infos)).len);
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
    try std.testing.expectEqualSlices(u8, &@as([3]u8, @splat(0xcc)), &second);
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
    const page_one = @as([512]u8, @splat(0xa5));
    const page_two = @as([512]u8, @splat(0x5a));
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
