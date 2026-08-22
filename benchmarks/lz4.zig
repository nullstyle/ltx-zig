const std = @import("std");
const lz4_block = @import("lz4_block");

const page_size: usize = 65_536;
const iterations: u32 = 1024;

pub fn main(init: std.process.Init) !void {
    var page: [page_size]u8 = undefined;
    var compressed: [lz4_block.compress_bound(page_size)]u8 = undefined;
    var workspace: lz4_block.CompressionWorkspace = .{};
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_file_writer: std.Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const writer = &stdout_file_writer.interface;

    @memset(&page, 0);
    try benchmark_case(init.io, writer, "zero", &page, &compressed, &workspace);

    fill_mixed(&page);
    try benchmark_case(init.io, writer, "mixed", &page, &compressed, &workspace);

    fill_lcg(&page);
    try benchmark_case(init.io, writer, "incompressible", &page, &compressed, &workspace);
    try writer.flush();
}

fn benchmark_case(
    io: std.Io,
    writer: *std.Io.Writer,
    name: []const u8,
    page: []u8,
    compressed: []u8,
    workspace: *lz4_block.CompressionWorkspace,
) !void {
    const reference = try lz4_block.encode(page, compressed, workspace);
    const encoded_size = reference.len;
    var checksum: usize = 0;
    const started = std.Io.Clock.awake.now(io).nanoseconds;
    var iteration: u32 = 0;
    while (iteration < iterations) : (iteration += 1) {
        const perturbation: u8 = @truncate(iteration + 1);
        page[page.len - 1] ^= perturbation;
        std.mem.doNotOptimizeAway(page);
        const encoded = try lz4_block.encode(page, compressed, workspace);
        std.mem.doNotOptimizeAway(encoded);
        checksum +%= encoded[iteration % encoded.len];
        page[page.len - 1] ^= perturbation;
    }
    const elapsed_ns: u128 = @intCast(std.Io.Clock.awake.now(io).nanoseconds - started);
    const bounded_elapsed = @max(elapsed_ns, 1);
    const input_bytes = @as(u128, page.len) * iterations;
    const bytes_per_second = input_bytes * std.time.ns_per_s / bounded_elapsed;
    const mebibytes_per_second = bytes_per_second / (1024 * 1024);
    const ratio_per_mille = @as(u128, encoded_size) * 1000 / page.len;
    std.mem.doNotOptimizeAway(checksum);

    try writer.print(
        "{s}: {d} -> {d} bytes ({d}.{d:0>3}), {d} MiB/s\n",
        .{
            name,
            page.len,
            encoded_size,
            ratio_per_mille / 1000,
            ratio_per_mille % 1000,
            mebibytes_per_second,
        },
    );
}

fn fill_lcg(page: []u8) void {
    var state: u32 = 0x1234_5678;
    for (page) |*byte| {
        state = state *% 1_664_525 +% 1_013_904_223;
        byte.* = @truncate(state >> 24);
    }
}

fn fill_mixed(page: []u8) void {
    fill_lcg(page);
    var chunk_index: usize = 0;
    var chunk_start: usize = 0;
    while (chunk_start < page.len) : (chunk_start += 97) {
        const chunk_end = @min(chunk_start + 97, page.len);
        if (chunk_index % 2 == 0) @memset(page[chunk_start..chunk_end], 0x5a);
        chunk_index += 1;
    }
}
