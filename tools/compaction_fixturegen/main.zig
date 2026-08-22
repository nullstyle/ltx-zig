const std = @import("std");
const ltx = @import("ltx");

const page_size = 512;
const max_inputs = 3;
const max_pages = 4;
const max_compressed_bytes = 530;
const max_file_bytes = 4096;

const limits = ltx.Limits{
    .max_input_bytes = max_file_bytes,
    .max_output_bytes = max_file_bytes,
    .max_pages = max_pages,
    .max_page_size = page_size,
    .max_compressed_page_size = max_compressed_bytes,
    .max_page_index_bytes = 128,
    .max_page_index_entries = max_pages,
    .max_varint_bytes = 10,
    .max_transaction_span = max_inputs,
};

const Page = struct {
    page_number: u32,
    data: []const u8,
};

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 2) return error.InvalidArguments;

    var output: [max_file_bytes]u8 = undefined;
    const output_bytes = if (std.mem.eql(u8, args[1], "merge"))
        try generate_merge(&output)
    else if (std.mem.eql(u8, args[1], "deletion"))
        try generate_deletion(&output)
    else if (std.mem.eql(u8, args[1], "no-checksum"))
        try generate_no_checksum(&output)
    else
        return error.InvalidArguments;

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: std.Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    try stdout_file_writer.interface.writeAll(output_bytes);
    try stdout_file_writer.interface.flush();
}

fn generate_merge(output: []u8) ![]const u8 {
    const page_11: [page_size]u8 = @splat(0x11);
    const page_12: [page_size]u8 = @splat(0x12);
    const page_13: [page_size]u8 = @splat(0x13);
    const page_21: [page_size]u8 = @splat(0x21);
    const page_24: [page_size]u8 = @splat(0x24);
    const page_32: [page_size]u8 = @splat(0x32);

    const initial_pages = [_]Page{
        .{ .page_number = 1, .data = &page_11 },
        .{ .page_number = 2, .data = &page_12 },
        .{ .page_number = 3, .data = &page_13 },
    };
    const second_pages = [_]Page{
        .{ .page_number = 1, .data = &page_21 },
        .{ .page_number = 4, .data = &page_24 },
    };
    const third_pages = [_]Page{.{ .page_number = 2, .data = &page_32 }};
    const after_second = [_]Page{
        .{ .page_number = 1, .data = &page_21 },
        .{ .page_number = 2, .data = &page_12 },
        .{ .page_number = 3, .data = &page_13 },
        .{ .page_number = 4, .data = &page_24 },
    };
    const after_third = [_]Page{
        .{ .page_number = 1, .data = &page_21 },
        .{ .page_number = 2, .data = &page_32 },
    };

    const post_one = try database_checksum(&initial_pages);
    const post_two = try database_checksum(&after_second);
    const post_three = try database_checksum(&after_third);
    var input_storage: [max_inputs][max_file_bytes]u8 = undefined;
    var input_lengths: [max_inputs]usize = undefined;
    input_lengths[0] = try encode_input(&input_storage[0], merge_header(1, 3, 1000, .init(0)), &initial_pages, post_one);
    input_lengths[1] = try encode_input(&input_storage[1], merge_header(2, 4, 2000, post_one), &second_pages, post_two);
    input_lengths[2] = try encode_input(&input_storage[2], merge_header(3, 2, 3000, post_two), &third_pages, post_three);

    const inputs = [_][]const u8{
        input_storage[0][0..input_lengths[0]],
        input_storage[1][0..input_lengths[1]],
        input_storage[2][0..input_lengths[2]],
    };
    return compact_inputs(output, &inputs);
}

fn generate_deletion(output: []u8) ![]const u8 {
    const page_41: [page_size]u8 = @splat(0x41);
    const initial_pages = [_]Page{.{ .page_number = 1, .data = &page_41 }};
    const no_pages = [_]Page{};
    const post_one = try database_checksum(&initial_pages);

    var input_storage: [2][max_file_bytes]u8 = undefined;
    const first_length = try encode_input(
        &input_storage[0],
        deletion_header(1, 1, 4000, .init(0)),
        &initial_pages,
        post_one,
    );
    const second_length = try encode_input(
        &input_storage[1],
        deletion_header(2, 0, 5000, post_one),
        &no_pages,
        .init(ltx.checksum_flag),
    );
    const inputs = [_][]const u8{
        input_storage[0][0..first_length],
        input_storage[1][0..second_length],
    };
    return compact_inputs(output, &inputs);
}

fn generate_no_checksum(output: []u8) ![]const u8 {
    const page_61: [page_size]u8 = @splat(0x61);
    const page_62: [page_size]u8 = @splat(0x62);
    const page_72: [page_size]u8 = @splat(0x72);
    const first_pages = [_]Page{
        .{ .page_number = 1, .data = &page_61 },
        .{ .page_number = 2, .data = &page_62 },
    };
    const second_pages = [_]Page{.{ .page_number = 2, .data = &page_72 }};

    var input_storage: [2][max_file_bytes]u8 = undefined;
    const first_length = try encode_input(
        &input_storage[0],
        no_checksum_header(4, 2, 6000, 600),
        &first_pages,
        .init(0),
    );
    const second_length = try encode_input(
        &input_storage[1],
        no_checksum_header(5, 2, 7000, 700),
        &second_pages,
        .init(0),
    );
    const inputs = [_][]const u8{
        input_storage[0][0..first_length],
        input_storage[1][0..second_length],
    };
    return compact_inputs(output, &inputs);
}

fn encode_input(
    destination: []u8,
    header: ltx.Header,
    pages: []const Page,
    post_apply_checksum: ltx.Checksum,
) !usize {
    var sink = ltx.SliceWriter.init(destination);
    var compressed_workspace: [max_compressed_bytes]u8 = undefined;
    var compression_workspace: ltx.LZ4CompressionWorkspace = undefined;
    var index_workspace: [max_pages]ltx.PageIndexEntry = undefined;
    var encoder = try ltx.Encoder.init(
        .v3,
        limits,
        sink.writer(),
        &compressed_workspace,
        &compression_workspace,
        &index_workspace,
    );
    try encoder.write_header(header);
    for (pages) |page| try encoder.write_page(page.page_number, page.data);
    const verified = try encoder.finish(post_apply_checksum);
    if (verified.byte_count != sink.written().len) return error.InvalidFixture;
    return sink.written().len;
}

fn compact_inputs(output: []u8, encoded_inputs: []const []const u8) ![]const u8 {
    var readers: [max_inputs]ltx.SliceReader = undefined;
    var inputs: [max_inputs]ltx.CompactionInput = undefined;
    var page_workspaces: [max_inputs][page_size]u8 = undefined;
    var compressed_workspaces: [max_inputs][max_compressed_bytes]u8 = undefined;
    var index_workspaces: [max_inputs][max_pages]ltx.PageIndexEntry = undefined;
    for (encoded_inputs, 0..) |bytes, index| {
        readers[index] = ltx.SliceReader.init(bytes);
        inputs[index] = ltx.CompactionInput.init(
            readers[index].reader(),
            &page_workspaces[index],
            &compressed_workspaces[index],
            &index_workspaces[index],
        );
    }

    var sink = ltx.SliceWriter.init(output);
    var output_compressed_workspace: [max_compressed_bytes]u8 = undefined;
    var output_compression_workspace: ltx.LZ4CompressionWorkspace = undefined;
    var output_index_workspace: [max_pages]ltx.PageIndexEntry = undefined;
    var compactor = try ltx.Compactor.init(
        .v3,
        limits,
        .{ .max_inputs = max_inputs, .max_total_pages = 16 },
        inputs[0..encoded_inputs.len],
        sink.writer(),
        &output_compressed_workspace,
        &output_compression_workspace,
        &output_index_workspace,
    );
    const verified = try compactor.compact();
    if (verified.byte_count != sink.written().len) return error.InvalidFixture;
    return sink.written();
}

fn database_checksum(pages: []const Page) !ltx.Checksum {
    var checksum = ltx.rolling_checksum_initial();
    for (pages) |page| {
        checksum = try ltx.rolling_checksum_add(
            checksum,
            try ltx.checksum_page(page.page_number, page.data),
        );
    }
    return checksum;
}

fn merge_header(
    txid: u64,
    commit: u32,
    timestamp_ms: i64,
    pre_apply_checksum: ltx.Checksum,
) ltx.Header {
    return metadata_header(txid, commit, timestamp_ms, pre_apply_checksum, txid * 100);
}

fn deletion_header(
    txid: u64,
    commit: u32,
    timestamp_ms: i64,
    pre_apply_checksum: ltx.Checksum,
) ltx.Header {
    return metadata_header(txid, commit, timestamp_ms, pre_apply_checksum, txid * 400);
}

fn no_checksum_header(
    txid: u64,
    commit: u32,
    timestamp_ms: i64,
    metadata_base: u64,
) ltx.Header {
    var header = metadata_header(txid, commit, timestamp_ms, .init(0), metadata_base);
    header.flags = ltx.header_flag_no_checksum;
    return header;
}

fn metadata_header(
    txid: u64,
    commit: u32,
    timestamp_ms: i64,
    pre_apply_checksum: ltx.Checksum,
    metadata_base: u64,
) ltx.Header {
    return .{
        .flags = 0,
        .page_size = page_size,
        .commit = commit,
        .min_txid = .init(txid),
        .max_txid = .init(txid),
        .timestamp_ms = timestamp_ms,
        .pre_apply_checksum = pre_apply_checksum,
        .wal_offset = @intCast(metadata_base),
        .wal_size = @intCast(metadata_base + 50),
        .wal_salt_1 = @intCast(metadata_base + 1),
        .wal_salt_2 = @intCast(metadata_base + 2),
        .node_id = metadata_base + 3,
    };
}
