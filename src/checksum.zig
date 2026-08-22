const std = @import("std");
const format = @import("format.zig");

const CRC64ISO = std.hash.crc.Crc64GoIso;

pub const FileHasher = struct {
    crc: CRC64ISO = CRC64ISO.init(),

    pub fn update(self: *FileHasher, bytes: []const u8) void {
        self.crc.update(bytes);
    }

    pub fn checksum(self: FileHasher) format.Checksum {
        return .init(format.checksum_flag | self.crc.final());
    }
};

pub fn crc64_iso(bytes: []const u8) u64 {
    return CRC64ISO.hash(bytes);
}

pub fn checksum_page(page_number: u32, page: []const u8) format.Error!format.Checksum {
    if (page_number == 0) return error.InvalidPageNumber;
    var page_number_bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &page_number_bytes, page_number, .big);
    var crc = CRC64ISO.init();
    crc.update(&page_number_bytes);
    crc.update(page);
    return .init(format.checksum_flag | crc.final());
}

pub fn rolling_initial() format.Checksum {
    return .init(format.checksum_flag);
}

pub fn rolling_add(
    current: format.Checksum,
    page_checksum: format.Checksum,
) format.Error!format.Checksum {
    if (!current.has_valid_flag()) return error.InvalidChecksumFormat;
    if (!page_checksum.has_valid_flag()) return error.InvalidChecksumFormat;
    return .init(format.checksum_flag | (current.value ^ page_checksum.value));
}

test "CRC-64/ISO matches the Go standard-library vector" {
    try std.testing.expectEqual(@as(u64, 0xb909_56c7_75a4_1001), crc64_iso("123456789"));
}

test "page and rolling checksums are independently known answers" {
    var page: [512]u8 = undefined;
    for (&page, 0..) |*byte, index| byte.* = @truncate(index);
    try std.testing.expectEqual(
        @as(u64, 0xc6f1_3286_cb62_cc9f),
        (try checksum_page(1, &page)).value,
    );
    const rolling = try rolling_add(rolling_initial(), try checksum_page(1, &page));
    try std.testing.expectEqual(@as(u64, 0xc6f1_3286_cb62_cc9f), rolling.value);
    try std.testing.expectEqual(format.checksum_flag, rolling_initial().value);
}

test "rolling checksum rejects an invalid flag on either operand" {
    const valid = rolling_initial();
    const invalid = format.Checksum.init(0);
    try std.testing.expectError(error.InvalidChecksumFormat, rolling_add(invalid, valid));
    try std.testing.expectError(error.InvalidChecksumFormat, rolling_add(valid, invalid));
}

test "rolling checksum matches the upstream three-page known answer" {
    const pages = [_][512]u8{
        @splat(0x01),
        @splat(0x02),
        @splat(0x03),
    };
    var rolling = rolling_initial();
    for (pages, 1..) |page, page_number| {
        rolling = try rolling_add(
            rolling,
            try checksum_page(@intCast(page_number), &page),
        );
    }
    try std.testing.expectEqual(@as(u64, 0xefff_ffff_ecd9_9000), rolling.value);
}
