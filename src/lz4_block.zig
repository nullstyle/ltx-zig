const std = @import("std");
const Error = @import("format.zig").Error;

const minimum_match_length: usize = 4;
const length_nibble_max: usize = 15;
const extension_byte_max: usize = 255;

pub fn literal_bound(input_length: u32) u32 {
    const length: u64 = input_length;
    const extension: u64 = if (length < length_nibble_max)
        0
    else
        1 + (length - length_nibble_max) / extension_byte_max;
    const bound = 1 + extension + length;
    std.debug.assert(bound <= std.math.maxInt(u32));
    return @intCast(bound);
}

pub fn encode_literal(input: []const u8, output: []u8) Error![]const u8 {
    if (input.len > std.math.maxInt(u32)) return error.CompressedPageLimitExceeded;
    const required: usize = literal_bound(@intCast(input.len));
    if (output.len < required) return error.WorkspaceTooSmall;

    const literal_nibble: u8 = @intCast(@min(input.len, length_nibble_max));
    output[0] = literal_nibble << 4;
    var output_index: usize = 1;
    if (input.len >= length_nibble_max) {
        var remaining = input.len - length_nibble_max;
        while (remaining >= extension_byte_max) : (remaining -= extension_byte_max) {
            output[output_index] = extension_byte_max;
            output_index += 1;
        }
        output[output_index] = @intCast(remaining);
        output_index += 1;
    }
    @memcpy(output[output_index..][0..input.len], input);
    output_index += input.len;
    std.debug.assert(output_index == required);
    return output[0..output_index];
}

pub fn decode(input: []const u8, output: []u8) Error!void {
    if (input.len == 0) return error.InvalidLZ4Block;
    var input_index: usize = 0;
    var output_index: usize = 0;
    var sequence_count: usize = 0;

    while (input_index < input.len) {
        if (sequence_count >= input.len) return error.InvalidLZ4Block;
        sequence_count += 1;
        const token = input[input_index];
        input_index += 1;

        const literal_base: usize = token >> 4;
        const literal_length = try read_length(input, &input_index, literal_base);
        try copy_literals(input, &input_index, output, &output_index, literal_length);
        if (input_index == input.len) {
            if (token & 0x0f != 0) return error.InvalidLZ4Block;
            break;
        }

        if (input.len - input_index < 2) return error.InvalidLZ4Block;
        const offset = @as(usize, input[input_index]) |
            (@as(usize, input[input_index + 1]) << 8);
        input_index += 2;
        if (offset == 0 or offset > output_index) return error.InvalidLZ4Block;

        const match_base: usize = token & 0x0f;
        const match_extra = try read_length(input, &input_index, match_base);
        const match_length = std.math.add(usize, match_extra, minimum_match_length) catch {
            return error.InvalidLZ4Block;
        };
        try copy_match(output, &output_index, offset, match_length);
    }
    if (output_index != output.len) return error.DecompressedSizeMismatch;
}

fn read_length(input: []const u8, input_index: *usize, base: usize) Error!usize {
    if (base != length_nibble_max) return base;
    var length = base;
    var extension_count: usize = 0;
    while (true) {
        if (input_index.* >= input.len) return error.InvalidLZ4Block;
        if (extension_count >= input.len) return error.InvalidLZ4Block;
        extension_count += 1;
        const byte = input[input_index.*];
        input_index.* += 1;
        length = std.math.add(usize, length, byte) catch return error.InvalidLZ4Block;
        if (byte != extension_byte_max) return length;
    }
}

fn copy_literals(
    input: []const u8,
    input_index: *usize,
    output: []u8,
    output_index: *usize,
    length: usize,
) Error!void {
    const input_end = std.math.add(usize, input_index.*, length) catch {
        return error.InvalidLZ4Block;
    };
    const output_end = std.math.add(usize, output_index.*, length) catch {
        return error.InvalidLZ4Block;
    };
    if (input_end > input.len or output_end > output.len) return error.InvalidLZ4Block;
    @memcpy(output[output_index.*..output_end], input[input_index.*..input_end]);
    input_index.* = input_end;
    output_index.* = output_end;
}

fn copy_match(output: []u8, output_index: *usize, offset: usize, length: usize) Error!void {
    const output_end = std.math.add(usize, output_index.*, length) catch {
        return error.InvalidLZ4Block;
    };
    if (output_end > output.len) return error.InvalidLZ4Block;
    var copied: usize = 0;
    while (copied < length) : (copied += 1) {
        const source_index = output_index.* - offset;
        output[output_index.*] = output[source_index];
        output_index.* += 1;
    }
    std.debug.assert(output_index.* == output_end);
}

test "literal encoder round trips the maximum SQLite page" {
    var page: [65_536]u8 = undefined;
    for (&page, 0..) |*byte, index| byte.* = @truncate(index *% 131);
    var compressed: [65_794]u8 = undefined;
    const encoded = try encode_literal(&page, &compressed);
    try std.testing.expectEqual(@as(usize, literal_bound(page.len)), encoded.len);
    var decoded: [65_536]u8 = undefined;
    try decode(encoded, &decoded);
    try std.testing.expectEqualSlices(u8, &page, &decoded);
}

test "decoder supports overlapping LZ4 matches" {
    const compressed = [_]u8{ 0x44, 'a', 'b', 'c', 'd', 0x04, 0x00 };
    var decoded: [12]u8 = undefined;
    try decode(&compressed, &decoded);
    try std.testing.expectEqualStrings("abcdabcdabcd", &decoded);
}

test "decoder accepts a compressed block emitted by pinned Go LZ4" {
    const compressed = [_]u8{
        0x1f, 0x00, 0x01, 0x00, 0xff, 0xda, 0x00, 0x02,
        0x00, 0x00, 0x02, 0x00, 0xb0, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    };
    var decoded: [512]u8 = undefined;
    try decode(&compressed, &decoded);
    try std.testing.expectEqualSlices(u8, &(@as([512]u8, @splat(0))), &decoded);
}

test "decoder rejects zero offsets and wrong output sizes" {
    var decoded: [8]u8 = undefined;
    try std.testing.expectError(
        error.InvalidLZ4Block,
        decode(&.{ 0x10, 'a', 0x00, 0x00 }, &decoded),
    );
    try std.testing.expectError(error.DecompressedSizeMismatch, decode("\x10a", &decoded));
}

test "terminal literal sequence cannot claim a missing match" {
    var decoded: [1]u8 = undefined;
    try std.testing.expectError(error.InvalidLZ4Block, decode("\x11a", &decoded));
}
