//! Crash child for the capture drill: opens a session, writes batches with
//! a sync after each, and reports each durable batch on stdout before
//! starting the next. The parent kills this process between reports; the
//! object tree then reflects exactly the reported batches.

const std = @import("std");
const ltx = @import("ltx");
const ltx_capture = @import("ltx_capture");
const ltx_object = @import("ltx_object");
const ltx_wal = @import("ltx_wal");

const page_size = 4096;

const codec_limits = ltx.Limits{
    .max_input_bytes = 1 << 20,
    .max_output_bytes = 1 << 20,
    .max_pages = 64,
    .max_page_size = page_size,
    .max_compressed_page_size = page_size + 1024,
    .max_page_index_bytes = 1 << 16,
    .max_page_index_entries = 64,
    .max_varint_bytes = 10,
    .max_transaction_span = 64,
};

const wal_limits = ltx_wal.Limits{
    .max_page_size = page_size,
    .max_pages = 64,
    .max_frames = 256,
};

var wal_storage: [1 << 20]u8 = undefined;
var slots: [64]ltx_wal.PageSlot = @splat(.{});
var pending: [64]u32 = @splat(0);
var seen: [8]u8 = @splat(0);
var entries: [64]ltx_wal.PageMapEntry =
    @splat(.{ .page_number = 0, .frame_offset_bytes = 0 });
var output: [1 << 20]u8 = undefined;
var page: [page_size]u8 = undefined;
var compressed: [page_size + 1024]u8 = undefined;
var compression: ltx.LZ4CompressionWorkspace = undefined;
var index: [64]ltx.PageIndexEntry =
    @splat(.{ .page_number = 0, .frame_offset_bytes = 0, .frame_size_bytes = 0 });
var workspaces: ltx_capture.Workspaces = .{
    .wal_storage = &wal_storage,
    .map_slots = &slots,
    .map_pending = &pending,
    .map_seen = &seen,
    .map_entries = &entries,
    .output_storage = &output,
    .page_workspace = &page,
    .compressed_workspace = &compressed,
    .compression_workspace = &compression,
    .index_workspace = &index,
};

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 3) return error.InvalidArguments;
    const io = init.io;
    var dir = try std.Io.Dir.cwd().openDir(io, args[1], .{
        .access_sub_paths = true,
    });
    defer dir.close(io);

    var store = try ltx_object.FileClient.init(dir, io, "replica");
    var session = try ltx_capture.Session.init(
        dir,
        io,
        args[2],
        codec_limits,
        wal_limits,
        store.client(),
    );
    defer session.finish();

    var out_buffer: [256]u8 = undefined;
    var out = std.Io.File.Writer.init(.stdout(), io, &out_buffer);
    const writer = &out.interface;

    try session.exec("CREATE TABLE kv (k INTEGER PRIMARY KEY, v TEXT)");
    var batch: u64 = 0;
    while (batch < 64) : (batch += 1) {
        var statement_buffer: [128]u8 = undefined;
        var row: u64 = 0;
        while (row < 8) : (row += 1) {
            const statement = try std.fmt.bufPrintZ(
                &statement_buffer,
                "INSERT INTO kv VALUES ({d}, 'b{d}r{d}')",
                .{ batch * 8 + row + 1, batch, row },
            );
            try session.exec(statement);
        }
        _ = try session.sync(&workspaces, @intCast(1000 + batch));
        try writer.print("batch {d} rows {d}\n", .{ batch, (batch + 1) * 8 });
        try writer.flush();
    }
}
