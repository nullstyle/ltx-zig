const std = @import("std");

pub const varint_size_max: u8 = 10;

pub fn encoded_length(value: u64) u8 {
    var remaining = value;
    var length: u8 = 1;
    while (remaining >= 0x80) : (remaining >>= 7) length += 1;
    std.debug.assert(length >= 1);
    std.debug.assert(length <= varint_size_max);
    return length;
}

pub fn encode(value: u64, buffer: *[varint_size_max]u8) []const u8 {
    var remaining = value;
    var index: u8 = 0;
    while (remaining >= 0x80) {
        buffer[index] = @as(u8, @truncate(remaining)) | 0x80;
        remaining >>= 7;
        index += 1;
    }
    buffer[index] = @truncate(remaining);
    index += 1;
    std.debug.assert(index == encoded_length(value));
    return buffer[0..index];
}

test "unsigned varints use the canonical Go encoding" {
    var buffer: [varint_size_max]u8 = undefined;
    try std.testing.expectEqualSlices(u8, &.{0x00}, encode(0, &buffer));
    try std.testing.expectEqualSlices(u8, &.{ 0xac, 0x02 }, encode(300, &buffer));
    try std.testing.expectEqualSlices(
        u8,
        &.{ 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x01 },
        encode(std.math.maxInt(u64), &buffer),
    );
}
