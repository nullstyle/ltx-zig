const std = @import("std");
const ltx = @import("ltx");

const limits = ltx.Limits{
    .max_input_bytes = 700,
    .max_output_bytes = 700,
    .max_pages = 1,
    .max_page_size = 512,
    .max_compressed_page_size = 515,
    .max_page_index_bytes = 32,
    .max_page_index_entries = 1,
    .max_varint_bytes = 10,
    .max_transaction_span = 1,
};

pub fn main(init: std.process.Init) !void {
    var output: [700]u8 = undefined;
    var sink = ltx.SliceWriter.init(&output);
    var compressed_workspace: [515]u8 = undefined;
    var index_workspace: [1]ltx.PageIndexEntry = undefined;
    var encoder = try ltx.Encoder.init(
        .v3,
        limits,
        sink.writer(),
        &compressed_workspace,
        &index_workspace,
    );
    try encoder.write_header(snapshot_header());
    const page: [512]u8 = @splat(0);
    try encoder.write_page(1, &page);
    _ = try encoder.finish(try ltx.checksum_page(1, &page));

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_file_writer: std.Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    try stdout_file_writer.interface.writeAll(sink.written());
    try stdout_file_writer.interface.flush();
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
