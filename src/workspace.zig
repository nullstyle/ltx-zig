const std = @import("std");

pub fn slices_overlap(left: []const u8, right: []const u8) bool {
    if (left.len == 0 or right.len == 0) return false;
    const left_start = @intFromPtr(left.ptr);
    const right_start = @intFromPtr(right.ptr);
    const left_end = std.math.add(usize, left_start, left.len) catch unreachable;
    const right_end = std.math.add(usize, right_start, right.len) catch unreachable;
    return left_start < right_end and right_start < left_end;
}

test "workspace overlap detects partial and exact aliases" {
    var bytes: [16]u8 = undefined;
    try std.testing.expect(slices_overlap(bytes[0..8], bytes[7..12]));
    try std.testing.expect(slices_overlap(bytes[0..8], bytes[0..8]));
    try std.testing.expect(!slices_overlap(bytes[0..8], bytes[8..16]));
}
