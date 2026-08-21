const std = @import("std");

pub fn read_u16_be(bytes: *const [2]u8) u16 {
    return std.mem.readInt(u16, bytes, .big);
}

pub fn read_u32_be(bytes: *const [4]u8) u32 {
    return std.mem.readInt(u32, bytes, .big);
}

pub fn read_u64_be(bytes: *const [8]u8) u64 {
    return std.mem.readInt(u64, bytes, .big);
}

pub fn write_u16_be(bytes: *[2]u8, value: u16) void {
    std.mem.writeInt(u16, bytes, value, .big);
}

pub fn write_u32_be(bytes: *[4]u8, value: u32) void {
    std.mem.writeInt(u32, bytes, value, .big);
}

pub fn write_u64_be(bytes: *[8]u8, value: u64) void {
    std.mem.writeInt(u64, bytes, value, .big);
}

test "big-endian primitives have independent wire answers" {
    var u16_bytes: [2]u8 = undefined;
    var u32_bytes: [4]u8 = undefined;
    var u64_bytes: [8]u8 = undefined;
    write_u16_be(&u16_bytes, 0x1234);
    write_u32_be(&u32_bytes, 0x1234_5678);
    write_u64_be(&u64_bytes, 0x0123_4567_89ab_cdef);
    try std.testing.expectEqualSlices(u8, &.{ 0x12, 0x34 }, &u16_bytes);
    try std.testing.expectEqualSlices(u8, &.{ 0x12, 0x34, 0x56, 0x78 }, &u32_bytes);
    try std.testing.expectEqualSlices(
        u8,
        &.{ 0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef },
        &u64_bytes,
    );
    try std.testing.expectEqual(@as(u16, 0x1234), read_u16_be(&u16_bytes));
    try std.testing.expectEqual(@as(u32, 0x1234_5678), read_u32_be(&u32_bytes));
    try std.testing.expectEqual(@as(u64, 0x0123_4567_89ab_cdef), read_u64_be(&u64_bytes));
}
