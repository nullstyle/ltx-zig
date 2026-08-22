const std = @import("std");
const ltx = @import("ltx");

const page_size_bytes = 512;
const output_capacity_bytes = 700;
const compressed_capacity_bytes = 530;

const limits = ltx.Limits{
    .max_input_bytes = output_capacity_bytes,
    .max_output_bytes = output_capacity_bytes,
    .max_pages = 1,
    .max_page_size = page_size_bytes,
    .max_compressed_page_size = compressed_capacity_bytes,
    .max_page_index_bytes = 32,
    .max_page_index_entries = 1,
    .max_varint_bytes = 10,
    .max_transaction_span = 1,
};

const Encoded = struct {
    length_bytes: usize,
    verified: ltx.VerifiedLTX,
};

pub fn main() !void {
    const page: [page_size_bytes]u8 = @splat(0);
    var output: [output_capacity_bytes]u8 = undefined;
    const encoded = try encode_snapshot(&output, &page);
    try decode_snapshot(output[0..encoded.length_bytes], &page, encoded.verified);
}

fn encode_snapshot(
    output: *[output_capacity_bytes]u8,
    page: *const [page_size_bytes]u8,
) !Encoded {
    var sink = ltx.SliceWriter.init(output);
    var compressed_workspace: [compressed_capacity_bytes]u8 = undefined;
    var lz4_workspace: ltx.LZ4CompressionWorkspace = undefined;
    var index_workspace: [1]ltx.PageIndexEntry = undefined;
    var encoder = try ltx.Encoder.init(
        .v3,
        limits,
        sink.writer(),
        &compressed_workspace,
        &lz4_workspace,
        &index_workspace,
    );
    try encoder.write_header(snapshot_header());
    try encoder.write_page(1, page);
    const verified = try encoder.finish(try ltx.checksum_page(1, page));
    return .{ .length_bytes = sink.written().len, .verified = verified };
}

fn decode_snapshot(
    encoded: []const u8,
    expected_page: *const [page_size_bytes]u8,
    expected: ltx.VerifiedLTX,
) !void {
    var source = ltx.SliceReader.init(encoded);
    var page_workspace: [page_size_bytes]u8 = undefined;
    var compressed_workspace: [compressed_capacity_bytes]u8 = undefined;
    var index_workspace: [1]ltx.PageIndexEntry = undefined;
    var decoder = try ltx.Decoder.init(
        .v3,
        limits,
        source.reader(),
        &page_workspace,
        &compressed_workspace,
        &index_workspace,
    );

    var event_count: u64 = 0;
    while (event_count < decoder.event_budget()) : (event_count += 1) {
        switch (try decoder.next()) {
            .header => |header| try check_header(event_count, header),
            .unverified_page => |page| try check_page(event_count, page, expected_page),
            .page_block_complete => if (event_count != 2) return error.UnexpectedEvent,
            .verified => |verified| {
                if (event_count != 3) return error.UnexpectedEvent;
                try check_verified(verified, expected);
                return;
            },
        }
    }
    return error.MissingVerifiedLTX;
}

fn check_header(event_count: u64, header: ltx.Header) !void {
    if (event_count != 0 or header.page_size != page_size_bytes or header.commit != 1) {
        return error.UnexpectedHeader;
    }
}

fn check_page(
    event_count: u64,
    page: ltx.UnverifiedPage,
    expected: *const [page_size_bytes]u8,
) !void {
    if (event_count != 1 or page.header.page_number != 1) return error.UnexpectedPage;
    if (!std.mem.eql(u8, page.data, expected)) return error.DecodedPageMismatch;
}

fn check_verified(actual: ltx.VerifiedLTX, expected: ltx.VerifiedLTX) !void {
    if (actual.page_count != 1 or actual.byte_count != expected.byte_count) {
        return error.UnexpectedVerifiedLTX;
    }
    if (actual.trailer.file_checksum.value != expected.trailer.file_checksum.value) {
        return error.FileChecksumMismatch;
    }
    const actual_position = actual.post_apply_position();
    const expected_position = expected.post_apply_position();
    if (actual_position.txid.value != expected_position.txid.value or
        actual_position.post_apply_checksum.value != expected_position.post_apply_checksum.value)
    {
        return error.PositionMismatch;
    }
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
