const std = @import("std");
const ltx = @import("ltx");
const captures = @import("litestream_captures");

const page_size: usize = 4096;
const max_inputs: usize = 4;
const max_pages: usize = 5;
const max_compressed_bytes: usize = 4200;
const max_file_bytes: usize = 4096;
const max_output_bytes: usize = 32 * 1024;

const codec_limits = ltx.Limits{
    .max_input_bytes = max_file_bytes,
    .max_output_bytes = max_output_bytes,
    .max_pages = max_pages,
    .max_page_size = page_size,
    .max_compressed_page_size = max_compressed_bytes,
    .max_page_index_bytes = max_file_bytes,
    .max_page_index_entries = max_pages,
    .max_varint_bytes = 10,
    .max_transaction_span = max_inputs,
};

const InputWorkspace = struct {
    source: ltx.SliceReader = undefined,
    page: [page_size]u8 = undefined,
    compressed: [max_compressed_bytes]u8 = undefined,
    index: [max_pages]ltx.PageIndexEntry = undefined,

    fn input(self: *InputWorkspace, bytes: []const u8) ltx.CompactionInput {
        self.source = ltx.SliceReader.init(bytes);
        return ltx.CompactionInput.init(
            self.source.reader(),
            &self.page,
            &self.compressed,
            &self.index,
        );
    }
};

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 1) return error.InvalidArguments;

    var input_workspaces: [max_inputs]InputWorkspace = undefined;
    var inputs: [max_inputs]ltx.CompactionInput = undefined;
    for (&inputs, 0..) |*input, index| {
        input.* = input_workspaces[index].input(captures.compaction_inputs[index]);
    }

    var output: [max_output_bytes]u8 = undefined;
    var sink = ltx.SliceWriter.init(&output);
    var compressed_workspace: [max_compressed_bytes]u8 = undefined;
    var compression_workspace: ltx.LZ4CompressionWorkspace = undefined;
    var index_workspace: [max_pages]ltx.PageIndexEntry = undefined;
    var compactor = try ltx.Compactor.init(
        .v3,
        codec_limits,
        .{ .max_inputs = max_inputs, .max_total_pages = 20 },
        &inputs,
        sink.writer(),
        &compressed_workspace,
        &compression_workspace,
        &index_workspace,
    );
    const verified = try compactor.compact();
    if (verified.byte_count != sink.written().len or verified.page_count != max_pages) {
        return error.InvalidFixture;
    }

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: std.Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    try stdout_file_writer.interface.writeAll(sink.written());
    try stdout_file_writer.interface.flush();
}
