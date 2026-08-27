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

var plain_send_workspace: [2 * multipart_part_bytes]u8 = undefined;
var plain_clock_context: u8 = 0;

var s3_under_test: ?ltx_s3.S3Client = null;

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
    var clock_context: u8 = 0;
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
                .context = &clock_context,
                .now_ms_fn = TestClock.now_ms,
            },
        },
        &send_workspace,
    );
    defer s3.deinit();
    try s3.ensure_bucket();
    try ltx_object.run_conformance(s3.client());
}

const multipart_part_bytes = 5 * 1024 * 1024;

var multipart_a: [multipart_part_bytes]u8 = undefined;
var multipart_b: [multipart_part_bytes]u8 = undefined;
var multipart_tail: [1024]u8 = undefined;
var multipart_recv: [2 * multipart_part_bytes + 1024]u8 = undefined;

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
    try client.delete(&.{.{ .level = 0, .min_txid = identity.min_txid, .max_txid = identity.max_txid }});
}
