const std = @import("std");
const Error = @import("format.zig").Error;
const lz4_block = @import("lz4_block.zig");

const frame_magic: u32 = 0x184d_2204;
const frame_header_size: usize = 7;
const block_size_bytes: usize = 4;
const footer_size: usize = 8;
const max_block_size: usize = 65_536;
const uncompressed_flag: u32 = @as(u32, 1) << 31;
const block_length_mask: u32 = uncompressed_flag - 1;
const upstream_flags: u8 = 0x64;
const upstream_block_descriptor: u8 = 0x40;

pub const Source = struct {
    context: *anyopaque,
    read_exact_fn: *const fn (context: *anyopaque, destination: []u8) Error!void,

    fn read_exact(self: Source, destination: []u8) Error!void {
        try self.read_exact_fn(self.context, destination);
    }
};

/// Streams one legacy LTX page frame and returns its encoded byte count. The
/// caller supplies separate payload and exact page-sized output workspaces.
pub fn decode(
    source: Source,
    compressed_workspace: []u8,
    output: []u8,
    max_compressed_page_size: u32,
) Error!u64 {
    if (output.len == 0 or output.len > max_block_size) {
        return error.DecompressedSizeMismatch;
    }
    var descriptor: [frame_header_size]u8 = undefined;
    try source.read_exact(&descriptor);
    try validate_frame_header(&descriptor);

    var block_header_bytes: [block_size_bytes]u8 = undefined;
    try source.read_exact(&block_header_bytes);
    const block_header = read_u32_le(&block_header_bytes);
    const block_length_u32 = block_header & block_length_mask;
    if (block_length_u32 == 0 or block_length_u32 > max_block_size) {
        return error.InvalidLZ4Frame;
    }
    if (block_length_u32 > max_compressed_page_size) {
        return error.CompressedPageLimitExceeded;
    }
    const block_length: usize = @intCast(block_length_u32);
    if (compressed_workspace.len < block_length) return error.WorkspaceTooSmall;
    const block = compressed_workspace[0..block_length];
    if (block_header & uncompressed_flag != 0 and block.len != output.len) {
        return error.DecompressedSizeMismatch;
    }
    try source.read_exact(block);

    if (block_header & uncompressed_flag != 0) {
        @memcpy(output, block);
    } else {
        try lz4_block.decode(block, output);
    }

    var end_marker: [4]u8 = undefined;
    try source.read_exact(&end_marker);
    if (read_u32_le(&end_marker) != 0) return error.UnsupportedPageEncoding;
    var content_checksum: [4]u8 = undefined;
    try source.read_exact(&content_checksum);
    const expected_checksum = read_u32_le(&content_checksum);
    if (std.hash.XxHash32.hash(0, output) != expected_checksum) {
        return error.LZ4ContentChecksumMismatch;
    }
    return frame_header_size + block_size_bytes + @as(u64, block_length_u32) + footer_size;
}

fn validate_frame_header(descriptor: *const [frame_header_size]u8) Error!void {
    if (read_u32_le(descriptor[0..4]) != frame_magic) return error.InvalidLZ4Frame;
    try validate_descriptor(descriptor[4], descriptor[5]);
    if (descriptor_checksum(descriptor[4..6]) != descriptor[6]) {
        return error.InvalidLZ4Frame;
    }
}

fn validate_descriptor(flags: u8, block_descriptor: u8) Error!void {
    // The Go oracle emits v1, independent 64 KiB blocks with a content
    // checksum and no optional content-size, block-checksum, or dictionary.
    const version = flags >> 6;
    if (version != 1 or flags & 0x02 != 0) return error.InvalidLZ4Frame;
    const block_size_index = (block_descriptor >> 4) & 0x07;
    if (block_descriptor & 0x8f != 0 or block_size_index < 4) {
        return error.InvalidLZ4Frame;
    }
    if (flags != upstream_flags or block_descriptor != upstream_block_descriptor) {
        return error.UnsupportedPageEncoding;
    }
}

fn descriptor_checksum(descriptor: []const u8) u8 {
    return @truncate(std.hash.XxHash32.hash(0, descriptor) >> 8);
}

fn read_u32_le(bytes: *const [4]u8) u32 {
    return std.mem.readInt(u32, bytes, .little);
}

test "decoder accepts the historical Go legacy page frame" {
    var stream: [historical_frame.len + 2]u8 = undefined;
    @memcpy(stream[0..historical_frame.len], &historical_frame);
    @memcpy(stream[historical_frame.len..], "zz");
    var source = SliceSource.init(&stream);
    var compressed: [24]u8 = undefined;
    var page: [512]u8 = undefined;

    const consumed = try decode(source.source(), &compressed, &page, compressed.len);

    try std.testing.expectEqual(historical_frame.len, consumed);
    try std.testing.expectEqual(historical_frame.len, source.offset);
    try std.testing.expectEqualStrings("zz", source.bytes[source.offset..]);
    try std.testing.expectEqualSlices(u8, &(@as([512]u8, @splat(0))), &page);
}

test "decoder supports an uncompressed independent block" {
    const frame = uncompressed_test_frame();
    var source = SliceSource.init(&frame);
    var compressed: [4]u8 = undefined;
    var output: [4]u8 = undefined;

    try std.testing.expectEqual(
        frame.len,
        try decode(source.source(), &compressed, &output, compressed.len),
    );
    try std.testing.expectEqualStrings("abcd", &output);
}

test "maximum stored block obeys the configured payload bound" {
    const encoded_size = frame_header_size + block_size_bytes + max_block_size + footer_size;
    var frame: [encoded_size]u8 = undefined;
    @memcpy(frame[0..frame_header_size], historical_frame[0..frame_header_size]);
    std.mem.writeInt(
        u32,
        frame[frame_header_size..][0..block_size_bytes],
        uncompressed_flag | @as(u32, max_block_size),
        .little,
    );
    const payload_start = frame_header_size + block_size_bytes;
    const payload = frame[payload_start..][0..max_block_size];
    for (payload, 0..) |*byte, index| byte.* = @truncate(index *% 131);
    const footer_start = payload_start + max_block_size;
    std.mem.writeInt(u32, frame[footer_start..][0..4], 0, .little);
    std.mem.writeInt(
        u32,
        frame[footer_start + 4 ..][0..4],
        std.hash.XxHash32.hash(0, payload),
        .little,
    );

    var compressed: [max_block_size]u8 = undefined;
    var output: [max_block_size]u8 = undefined;
    var source = SliceSource.init(&frame);
    try std.testing.expectEqual(
        @as(u64, encoded_size),
        try decode(source.source(), &compressed, &output, @intCast(max_block_size)),
    );
    try std.testing.expectEqualSlices(u8, payload, &output);

    var limited_source = SliceSource.init(&frame);
    try std.testing.expectError(
        error.CompressedPageLimitExceeded,
        decode(limited_source.source(), &compressed, &output, @intCast(max_block_size - 1)),
    );
    try std.testing.expectEqual(frame_header_size + block_size_bytes, limited_source.offset);
}

test "decoder enforces the exact output length" {
    const frame = uncompressed_test_frame();
    var compressed: [4]u8 = undefined;
    var short: [3]u8 = undefined;
    var long: [5]u8 = undefined;
    var short_source = SliceSource.init(&frame);
    try std.testing.expectError(
        error.DecompressedSizeMismatch,
        decode(short_source.source(), &compressed, &short, compressed.len),
    );
    var long_source = SliceSource.init(&frame);
    try std.testing.expectError(
        error.DecompressedSizeMismatch,
        decode(long_source.source(), &compressed, &long, compressed.len),
    );
}

test "decoder verifies descriptor and content checksums" {
    var frame = historical_frame;
    var compressed: [24]u8 = undefined;
    var output: [512]u8 = undefined;

    frame[6] ^= 1;
    var header_source = SliceSource.init(&frame);
    try std.testing.expectError(
        error.InvalidLZ4Frame,
        decode(header_source.source(), &compressed, &output, compressed.len),
    );
    frame = historical_frame;
    frame[frame.len - 1] ^= 1;
    var content_source = SliceSource.init(&frame);
    try std.testing.expectError(
        error.LZ4ContentChecksumMismatch,
        decode(content_source.source(), &compressed, &output, compressed.len),
    );
}

test "decoder rejects frame features outside the upstream profile" {
    const changes = [_]struct { index: usize, value: u8 }{
        .{ .index = 4, .value = 0x44 }, // dependent blocks
        .{ .index = 4, .value = 0x60 }, // no content checksum
        .{ .index = 4, .value = 0x74 }, // block checksum
        .{ .index = 4, .value = 0x6c }, // content size
        .{ .index = 4, .value = 0x65 }, // dictionary identifier
        .{ .index = 5, .value = 0x50 }, // block size above 64 KiB
    };
    var compressed: [24]u8 = undefined;
    var output: [512]u8 = undefined;

    for (changes) |change| {
        var frame = historical_frame;
        frame[change.index] = change.value;
        frame[6] = descriptor_checksum(frame[4..6]);
        var source = SliceSource.init(&frame);
        try std.testing.expectError(
            error.UnsupportedPageEncoding,
            decode(source.source(), &compressed, &output, compressed.len),
        );
    }
}

test "optional-field profiles are classified before their variable checksum position" {
    var frame = historical_frame;
    frame[4] = 0x6c; // content-size field follows BD before the descriptor checksum
    frame[6] = descriptor_checksum(frame[4..6]) ^ 1;
    var compressed: [24]u8 = undefined;
    var output: [512]u8 = undefined;
    var source = SliceSource.init(&frame);

    try std.testing.expectError(
        error.UnsupportedPageEncoding,
        decode(source.source(), &compressed, &output, compressed.len),
    );
}

test "decoder rejects malformed descriptor fields" {
    const changes = [_]struct { index: usize, value: u8 }{
        .{ .index = 4, .value = 0xa4 }, // invalid version
        .{ .index = 4, .value = 0x66 }, // reserved FLG bit
        .{ .index = 5, .value = 0x30 }, // invalid block-size index
        .{ .index = 5, .value = 0x41 }, // reserved low BD bit
        .{ .index = 5, .value = 0xc0 }, // reserved high BD bit
    };
    var compressed: [24]u8 = undefined;
    var output: [512]u8 = undefined;

    for (changes) |change| {
        var frame = historical_frame;
        frame[change.index] = change.value;
        frame[6] = descriptor_checksum(frame[4..6]);
        var source = SliceSource.init(&frame);
        try std.testing.expectError(
            error.InvalidLZ4Frame,
            decode(source.source(), &compressed, &output, compressed.len),
        );
    }
}

test "decoder rejects extra blocks and invalid frame block sizes" {
    var frame = uncompressed_test_frame();
    var compressed: [4]u8 = undefined;
    var output: [4]u8 = undefined;
    std.mem.writeInt(u32, frame[15..19], uncompressed_flag | 1, .little);
    var extra_source = SliceSource.init(&frame);
    try std.testing.expectError(
        error.UnsupportedPageEncoding,
        decode(extra_source.source(), &compressed, &output, compressed.len),
    );
    try std.testing.expectEqual(@as(usize, 19), extra_source.offset);

    frame = uncompressed_test_frame();
    std.mem.writeInt(u32, frame[7..11], max_block_size + 1, .little);
    var oversized_source = SliceSource.init(&frame);
    try std.testing.expectError(
        error.InvalidLZ4Frame,
        decode(oversized_source.source(), &compressed, &output, std.math.maxInt(u32)),
    );

    frame = uncompressed_test_frame();
    @memset(frame[7..11], 0);
    var zero_source = SliceSource.init(&frame);
    try std.testing.expectError(
        error.InvalidLZ4Frame,
        decode(zero_source.source(), &compressed, &output, compressed.len),
    );
    try std.testing.expectEqual(frame_header_size + block_size_bytes, zero_source.offset);
}

test "compressed size limits and workspace are checked before payload reads" {
    const frame = uncompressed_test_frame();
    var output: [4]u8 = undefined;
    var compressed: [4]u8 = undefined;
    var limited_source = SliceSource.init(&frame);
    try std.testing.expectError(
        error.CompressedPageLimitExceeded,
        decode(limited_source.source(), &compressed, &output, 3),
    );
    try std.testing.expectEqual(frame_header_size + block_size_bytes, limited_source.offset);

    var short_workspace: [3]u8 = undefined;
    var workspace_source = SliceSource.init(&frame);
    try std.testing.expectError(
        error.WorkspaceTooSmall,
        decode(workspace_source.source(), &short_workspace, &output, 4),
    );
    try std.testing.expectEqual(frame_header_size + block_size_bytes, workspace_source.offset);
}

test "decoder reports truncated descriptor and footer reads" {
    const frame = uncompressed_test_frame();
    var compressed: [4]u8 = undefined;
    var output: [4]u8 = undefined;
    var header_source = SliceSource.init(frame[0..6]);
    try std.testing.expectError(
        error.TruncatedInput,
        decode(header_source.source(), &compressed, &output, compressed.len),
    );
    var footer_source = SliceSource.init(frame[0 .. frame.len - 1]);
    try std.testing.expectError(
        error.TruncatedInput,
        decode(footer_source.source(), &compressed, &output, compressed.len),
    );
}

// Exact LZ4 frame at byte 106 of go_v3_legacy_unflagged.ltx, generated by
// superfly/ltx commit 133c1b1dba55dfb8033affedb3d400aaa3d8b807.
const historical_frame = [_]u8{
    0x04, 0x22, 0x4d, 0x18, 0x64, 0x40, 0xa7,
    0x18, 0x00, 0x00, 0x00, 0x1f, 0x00, 0x01,
    0x00, 0xff, 0xda, 0x00, 0x02, 0x00, 0x00,
    0x02, 0x00, 0xb0, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0xde, 0x53, 0xc1,
    0x32,
};

const SliceSource = struct {
    bytes: []const u8,
    offset: usize = 0,

    fn init(bytes: []const u8) SliceSource {
        return .{ .bytes = bytes };
    }

    fn source(self: *SliceSource) Source {
        return .{ .context = self, .read_exact_fn = read_exact };
    }

    fn read_exact(context: *anyopaque, destination: []u8) Error!void {
        const self: *SliceSource = @ptrCast(@alignCast(context));
        if (destination.len > self.bytes.len -| self.offset) return error.TruncatedInput;
        const end = self.offset + destination.len;
        @memcpy(destination, self.bytes[self.offset..end]);
        self.offset = end;
    }
};

fn uncompressed_test_frame() [23]u8 {
    var frame = [_]u8{
        0x04, 0x22, 0x4d, 0x18, 0x64, 0x40, 0xa7,
        0x04, 0x00, 0x00, 0x80, 'a',  'b',  'c',
        'd',  0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00,
    };
    std.mem.writeInt(u32, frame[19..23], std.hash.XxHash32.hash(0, "abcd"), .little);
    return frame;
}
