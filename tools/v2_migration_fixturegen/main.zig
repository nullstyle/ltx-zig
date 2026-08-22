const std = @import("std");
const ltx = @import("ltx");
const migration_inputs = @import("v2_migration_inputs");

const page_size: usize = 512;
const max_inputs: usize = 2;
const max_pages: usize = 8;
const max_compressed_bytes: usize = 700;
const max_file_bytes: usize = 4096;

const limits = ltx.Limits{
    .max_input_bytes = max_file_bytes,
    .max_output_bytes = max_file_bytes,
    .max_pages = max_pages,
    .max_page_size = page_size,
    .max_compressed_page_size = max_compressed_bytes,
    .max_page_index_bytes = 512,
    .max_page_index_entries = max_pages,
    .max_varint_bytes = 10,
    .max_transaction_span = 4,
};

const InputSpec = struct {
    version: ltx.FormatVersion,
    bytes: []const u8,
};

const InputWorkspace = struct {
    source: ltx.SliceReader = undefined,
    page: [page_size]u8 = undefined,
    compressed: [max_compressed_bytes]u8 = undefined,
    index: [max_pages]ltx.PageIndexEntry = undefined,

    fn input(self: *InputWorkspace, spec: InputSpec) ltx.CompactionInput {
        self.source = ltx.SliceReader.init(spec.bytes);
        return ltx.CompactionInput.init(
            spec.version,
            self.source.reader(),
            &self.page,
            &self.compressed,
            &self.index,
        );
    }
};

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 2) return error.InvalidArguments;

    var output: [max_file_bytes]u8 = undefined;
    const bytes = if (std.mem.eql(u8, args[1], "v2-only"))
        try generate_v2_only(&output)
    else if (std.mem.eql(u8, args[1], "mixed"))
        try generate_mixed(&output)
    else if (std.mem.eql(u8, args[1], "sqlite-empty"))
        try generate_sqlite_empty(&output)
    else
        return error.InvalidArguments;

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: std.Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    try stdout_file_writer.interface.writeAll(bytes);
    try stdout_file_writer.interface.flush();
}

fn generate_v2_only(output: []u8) ![]const u8 {
    const specs = [_]InputSpec{
        .{ .version = .v2, .bytes = migration_inputs.mixed },
        .{ .version = .v2, .bytes = migration_inputs.incremental },
    };
    return compact(output, &specs, 3);
}

fn generate_mixed(output: []u8) ![]const u8 {
    var current_storage: [1024]u8 = undefined;
    const current_incremental = try encode_current_incremental(&current_storage);
    const specs = [_]InputSpec{
        .{ .version = .v2, .bytes = migration_inputs.mixed },
        .{ .version = .v3, .bytes = current_incremental },
    };
    return compact(output, &specs, 3);
}

fn generate_sqlite_empty(output: []u8) ![]const u8 {
    const specs = [_]InputSpec{.{ .version = .v2, .bytes = migration_inputs.sqlite_empty }};
    return compact(output, &specs, 1);
}

fn encode_current_incremental(destination: []u8) ![]const u8 {
    var sink = ltx.SliceWriter.init(destination);
    var compressed: [max_compressed_bytes]u8 = undefined;
    var compression: ltx.LZ4CompressionWorkspace = undefined;
    var index: [max_pages]ltx.PageIndexEntry = undefined;
    var encoder = try ltx.Encoder.init(
        .v3,
        limits,
        sink.writer(),
        &compressed,
        &compression,
        &index,
    );
    try encoder.write_header(.{
        .flags = 0,
        .page_size = page_size,
        .commit = 3,
        .min_txid = .init(2),
        .max_txid = .init(4),
        .timestamp_ms = -1000,
        .pre_apply_checksum = .init(0xff27_3ef8_3077_8b70),
        .wal_offset = 0,
        .wal_size = 0,
        .wal_salt_1 = 0,
        .wal_salt_2 = 0,
        .node_id = 0,
    });
    const page_31: [page_size]u8 = @splat(0x31);
    const page_33: [page_size]u8 = @splat(0x33);
    try encoder.write_page(1, &page_31);
    try encoder.write_page(3, &page_33);
    const verified = try encoder.finish(.init(0xb6a0_600a_0173_c6ad));
    if (verified.byte_count != sink.written().len) return error.InvalidFixture;
    return sink.written();
}

fn compact(output: []u8, specs: []const InputSpec, expected_pages: u32) ![]const u8 {
    var workspaces: [max_inputs]InputWorkspace = undefined;
    var inputs: [max_inputs]ltx.CompactionInput = undefined;
    for (specs, 0..) |spec, index| inputs[index] = workspaces[index].input(spec);

    var sink = ltx.SliceWriter.init(output);
    var compressed: [max_compressed_bytes]u8 = undefined;
    var compression: ltx.LZ4CompressionWorkspace = undefined;
    var index: [max_pages]ltx.PageIndexEntry = undefined;
    var compactor = try ltx.Compactor.init(
        .v3,
        limits,
        .{ .max_inputs = max_inputs, .max_total_pages = 8 },
        inputs[0..specs.len],
        sink.writer(),
        &compressed,
        &compression,
        &index,
    );
    const verified = try compactor.compact();
    if (verified.byte_count != sink.written().len or verified.page_count != expected_pages) {
        return error.InvalidFixture;
    }
    return sink.written();
}
