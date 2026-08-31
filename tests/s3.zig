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
    const first = try client.open(0, .{
        .min_txid = ltx.TXID.init(1),
        .max_txid = ltx.TXID.init(1),
    }, &object_storage);
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
    const claimed = try client.open(0, fence, &object_storage);
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
    const stored = try client.open(0, identity, &multipart_recv);
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
        client.open(0, identity, &received),
    );

    try session.finish();
    try std.testing.expectEqual(
        ltx_object.WriteSessionState.final,
        session.current_state(),
    );
    try std.testing.expect(s3.multipart == null);
    try std.testing.expectEqualStrings(
        "transactional small object",
        try client.open(0, identity, &received),
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
        client.open(0, identity, &multipart_recv),
    );

    try session.finish();
    try std.testing.expect(s3.multipart == null);
    const stored = try client.open(0, identity, &multipart_recv);
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
        client.open(0, identity, &multipart_recv),
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
        client.open(0, identity, &received),
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
        try client.open(0, identity, &storage),
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
        try client.open(0, identity, &storage),
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
        try client.open(0, identity, &storage),
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
