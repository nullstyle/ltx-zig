const std = @import("std");
const Limits = @import("limits.zig").Limits;
const wire = @import("wire.zig");

pub const magic = "LTX1".*;
pub const header_size: u32 = 100;
pub const page_header_size: u32 = 6;
pub const page_size_prefix_size: u32 = 4;
pub const trailer_size: u32 = 16;
pub const checksum_size: u32 = 8;
pub const trailer_checksum_offset: u32 = trailer_size - checksum_size;
pub const sqlite_page_size_min: u32 = 512;
pub const sqlite_page_size_max: u32 = 65_536;
pub const sqlite_pending_byte: u64 = 0x4000_0000;
pub const checksum_flag: u64 = @as(u64, 1) << 63;
pub const header_flag_no_checksum: u32 = @as(u32, 1) << 1;
pub const page_header_flag_size: u16 = @as(u16, 1) << 0;

const header_magic_offset = 0;
const header_flags_offset = 4;
const header_page_size_offset = 8;
const header_commit_offset = 12;
const header_min_txid_offset = 16;
const header_max_txid_offset = 24;
const header_timestamp_offset = 32;
const header_pre_checksum_offset = 40;
const header_wal_offset_offset = 48;
const header_wal_size_offset = 56;
const header_wal_salt_1_offset = 64;
const header_wal_salt_2_offset = 68;
const header_node_id_offset = 72;
const header_reserved_offset = 80;
const header_reserved_size = 20;
const page_header_flags_offset = 4;

pub const Error = error{
    UnsupportedFormatVersion,
    UnsupportedPageEncoding,
    InvalidLimits,
    WorkspaceTooSmall,
    InputFailure,
    OutputFailure,
    InputLimitExceeded,
    OutputLimitExceeded,
    PageLimitExceeded,
    PageSizeLimitExceeded,
    CompressedPageLimitExceeded,
    PageIndexLimitExceeded,
    TransactionSpanLimitExceeded,
    TruncatedInput,
    TrailingBytes,
    InvalidMagic,
    InvalidHeaderFlags,
    InvalidPageSize,
    InvalidTXIDRange,
    InvalidChecksumFormat,
    InvalidPreApplyChecksum,
    InvalidWALMetadata,
    InvalidPageFlags,
    InvalidPageNumber,
    InvalidPageDataSize,
    PageOutOfOrder,
    SnapshotPageSequence,
    LockPagePresent,
    InvalidCompressedSize,
    InvalidLZ4Block,
    InvalidLZ4Frame,
    LZ4ContentChecksumMismatch,
    DecompressedSizeMismatch,
    VarintOverflow,
    OverlongVarint,
    InvalidPageIndex,
    PageIndexMismatch,
    InvalidPageIndexSize,
    InvalidTrailer,
    ChecksumMismatch,
    SnapshotChecksumMismatch,
    DatabaseChecksumMismatch,
    NonContiguousTransition,
    DivergentHistory,
    DatabasePageLimitExceeded,
    DatabaseSizeLimitExceeded,
    DatabasePageSizeMismatch,
    ApplyBeginFailure,
    ApplyStageFailure,
    ApplyReadFailure,
    ApplyPublishFailure,
    ApplyPublishIndeterminate,
    WorkspaceAliasing,
    InvalidState,
};

pub const FormatVersion = enum(u8) {
    v3 = 3,
    _,

    pub fn validate(self: FormatVersion) Error!void {
        if (self != .v3) return error.UnsupportedFormatVersion;
    }
};

pub const TXID = struct {
    value: u64,

    pub fn init(value: u64) TXID {
        return .{ .value = value };
    }
};

pub const Checksum = struct {
    value: u64,

    pub fn init(value: u64) Checksum {
        return .{ .value = value };
    }

    pub fn has_valid_flag(self: Checksum) bool {
        return self.value & checksum_flag != 0;
    }
};

pub const Position = struct {
    txid: TXID,
    post_apply_checksum: Checksum,
};

pub const Header = struct {
    flags: u32,
    page_size: u32,
    commit: u32,
    min_txid: TXID,
    max_txid: TXID,
    timestamp_ms: i64,
    pre_apply_checksum: Checksum,
    wal_offset: i64,
    wal_size: i64,
    wal_salt_1: u32,
    wal_salt_2: u32,
    node_id: u64,

    pub fn is_snapshot(self: Header) bool {
        return self.min_txid.value == 1;
    }

    pub fn no_checksum(self: Header) bool {
        return self.flags & header_flag_no_checksum != 0;
    }

    pub fn pre_apply_position(self: Header) Error!Position {
        if (self.min_txid.value == 0) return error.InvalidTXIDRange;
        return .{
            .txid = .init(self.min_txid.value - 1),
            .post_apply_checksum = self.pre_apply_checksum,
        };
    }

    pub fn check_contiguous(self: Header, current: Position) Error!void {
        const expected = try self.pre_apply_position();
        if (current.txid.value != expected.txid.value) {
            return error.NonContiguousTransition;
        }
        if (!self.no_checksum() and
            current.post_apply_checksum.value != expected.post_apply_checksum.value)
        {
            return error.DivergentHistory;
        }
    }

    pub fn validate(self: Header, limits: Limits) Error!void {
        if (self.flags & ~header_flag_no_checksum != 0) {
            return error.InvalidHeaderFlags;
        }
        if (!is_valid_page_size(self.page_size)) return error.InvalidPageSize;
        if (self.page_size > limits.max_page_size) return error.PageSizeLimitExceeded;
        try self.validate_txids(limits);
        try self.validate_wal();
        try self.validate_pre_apply_checksum();
        try self.validate_snapshot_limits(limits);
    }

    fn validate_txids(self: Header, limits: Limits) Error!void {
        if (self.min_txid.value == 0 or self.max_txid.value == 0) {
            return error.InvalidTXIDRange;
        }
        if (self.min_txid.value > self.max_txid.value) {
            return error.InvalidTXIDRange;
        }
        const difference = self.max_txid.value - self.min_txid.value;
        const span = difference + 1;
        if (span > limits.max_transaction_span) {
            return error.TransactionSpanLimitExceeded;
        }
    }

    fn validate_wal(self: Header) Error!void {
        if (self.wal_offset < 0 or self.wal_size < 0) {
            return error.InvalidWALMetadata;
        }
        if ((self.wal_salt_1 != 0 or self.wal_salt_2 != 0) and self.wal_offset == 0) {
            return error.InvalidWALMetadata;
        }
        if (self.wal_size != 0 and self.wal_offset == 0) {
            return error.InvalidWALMetadata;
        }
    }

    fn validate_pre_apply_checksum(self: Header) Error!void {
        if (self.is_snapshot()) {
            if (self.pre_apply_checksum.value != 0) return error.InvalidPreApplyChecksum;
        } else if (self.no_checksum()) {
            if (self.pre_apply_checksum.value != 0) return error.InvalidPreApplyChecksum;
        } else if (!self.pre_apply_checksum.has_valid_flag()) {
            return error.InvalidPreApplyChecksum;
        }
    }

    fn validate_snapshot_limits(self: Header, limits: Limits) Error!void {
        if (!self.is_snapshot()) return;
        const lock_page = lock_page_number_valid(self.page_size);
        const required = self.commit - @as(u32, @intFromBool(lock_page <= self.commit));
        if (required > limits.max_pages) return error.PageLimitExceeded;
        if (required > limits.max_page_index_entries) {
            return error.PageIndexLimitExceeded;
        }
    }
};

pub const PageHeader = struct {
    page_number: u32,
    flags: u16,

    pub fn is_terminator(self: PageHeader) bool {
        return self.page_number == 0 and self.flags == 0;
    }

    pub fn validate(self: PageHeader) Error!void {
        if (self.page_number == 0) return error.InvalidPageNumber;
        if (self.flags & ~page_header_flag_size != 0) return error.InvalidPageFlags;
    }
};

pub const PageIndexEntry = struct {
    page_number: u32,
    frame_offset_bytes: u64,
    frame_size_bytes: u64,
};

pub const Trailer = struct {
    post_apply_checksum: Checksum,
    file_checksum: Checksum,

    pub fn validate(self: Trailer, header: Header) Error!void {
        if (header.no_checksum()) {
            if (self.post_apply_checksum.value != 0) return error.InvalidTrailer;
        } else if (!self.post_apply_checksum.has_valid_flag()) {
            return error.InvalidTrailer;
        }
        if (!header.no_checksum() and header.commit == 0 and
            self.post_apply_checksum.value != checksum_flag)
        {
            return error.InvalidTrailer;
        }
        if (!self.file_checksum.has_valid_flag()) return error.InvalidTrailer;
    }
};

pub const UnverifiedPage = struct {
    header: PageHeader,
    data: []const u8,
};

pub const VerifiedLTX = struct {
    format_version: FormatVersion,
    header: Header,
    trailer: Trailer,
    page_count: u32,
    byte_count: u64,

    pub fn pre_apply_position(self: VerifiedLTX) Error!Position {
        return self.header.pre_apply_position();
    }

    pub fn post_apply_position(self: VerifiedLTX) Position {
        return .{
            .txid = self.header.max_txid,
            .post_apply_checksum = self.trailer.post_apply_checksum,
        };
    }

    pub fn check_contiguous(self: VerifiedLTX, current: Position) Error!void {
        try self.header.check_contiguous(current);
    }
};

pub fn is_valid_page_size(page_size: u32) bool {
    return page_size >= sqlite_page_size_min and
        page_size <= sqlite_page_size_max and
        std.math.isPowerOfTwo(page_size);
}

pub fn lock_page_number(page_size: u32) Error!u32 {
    if (!is_valid_page_size(page_size)) return error.InvalidPageSize;
    return lock_page_number_valid(page_size);
}

fn lock_page_number_valid(page_size: u32) u32 {
    std.debug.assert(is_valid_page_size(page_size));
    const page = sqlite_pending_byte / @as(u64, page_size) + 1;
    std.debug.assert(page <= std.math.maxInt(u32));
    return @intCast(page);
}

pub fn encode_header(header: Header, destination: *[header_size]u8) void {
    destination.* = @splat(0);
    @memcpy(destination[0..4], &magic);
    wire.write_u32_be(destination[4..8], header.flags);
    wire.write_u32_be(destination[8..12], header.page_size);
    wire.write_u32_be(destination[12..16], header.commit);
    wire.write_u64_be(destination[16..24], header.min_txid.value);
    wire.write_u64_be(destination[24..32], header.max_txid.value);
    wire.write_u64_be(destination[32..40], @bitCast(header.timestamp_ms));
    wire.write_u64_be(destination[40..48], header.pre_apply_checksum.value);
    wire.write_u64_be(destination[48..56], @bitCast(header.wal_offset));
    wire.write_u64_be(destination[56..64], @bitCast(header.wal_size));
    wire.write_u32_be(destination[64..68], header.wal_salt_1);
    wire.write_u32_be(destination[68..72], header.wal_salt_2);
    wire.write_u64_be(destination[72..80], header.node_id);
}

pub fn decode_header(source: *const [header_size]u8) Error!Header {
    if (!std.mem.eql(u8, source[0..4], &magic)) return error.InvalidMagic;
    return .{
        .flags = wire.read_u32_be(source[4..8]),
        .page_size = wire.read_u32_be(source[8..12]),
        .commit = wire.read_u32_be(source[12..16]),
        .min_txid = .init(wire.read_u64_be(source[16..24])),
        .max_txid = .init(wire.read_u64_be(source[24..32])),
        .timestamp_ms = @bitCast(wire.read_u64_be(source[32..40])),
        .pre_apply_checksum = .init(wire.read_u64_be(source[40..48])),
        .wal_offset = @bitCast(wire.read_u64_be(source[48..56])),
        .wal_size = @bitCast(wire.read_u64_be(source[56..64])),
        .wal_salt_1 = wire.read_u32_be(source[64..68]),
        .wal_salt_2 = wire.read_u32_be(source[68..72]),
        .node_id = wire.read_u64_be(source[72..80]),
    };
}

pub fn encode_page_header(header: PageHeader, destination: *[page_header_size]u8) void {
    wire.write_u32_be(destination[0..4], header.page_number);
    wire.write_u16_be(destination[4..6], header.flags);
}

pub fn decode_page_header(source: *const [page_header_size]u8) PageHeader {
    return .{
        .page_number = wire.read_u32_be(source[0..4]),
        .flags = wire.read_u16_be(source[4..6]),
    };
}

pub fn encode_trailer(trailer: Trailer, destination: *[trailer_size]u8) void {
    wire.write_u64_be(destination[0..8], trailer.post_apply_checksum.value);
    wire.write_u64_be(destination[8..16], trailer.file_checksum.value);
}

pub fn decode_trailer(source: *const [trailer_size]u8) Trailer {
    return .{
        .post_apply_checksum = .init(wire.read_u64_be(source[0..8])),
        .file_checksum = .init(wire.read_u64_be(source[8..16])),
    };
}

comptime {
    std.debug.assert(@sizeOf(TXID) == 8);
    std.debug.assert(@sizeOf(Checksum) == checksum_size);
    std.debug.assert(header_size == 100);
    std.debug.assert(page_header_size == 6);
    std.debug.assert(trailer_size == 2 * checksum_size);
    std.debug.assert(trailer_checksum_offset + checksum_size == trailer_size);
    std.debug.assert(header_magic_offset == 0);
    std.debug.assert(header_flags_offset + 4 == header_page_size_offset);
    std.debug.assert(header_page_size_offset + 4 == header_commit_offset);
    std.debug.assert(header_commit_offset + 4 == header_min_txid_offset);
    std.debug.assert(header_min_txid_offset + 8 == header_max_txid_offset);
    std.debug.assert(header_max_txid_offset + 8 == header_timestamp_offset);
    std.debug.assert(header_timestamp_offset + 8 == header_pre_checksum_offset);
    std.debug.assert(header_pre_checksum_offset + 8 == header_wal_offset_offset);
    std.debug.assert(header_wal_offset_offset + 8 == header_wal_size_offset);
    std.debug.assert(header_wal_size_offset + 8 == header_wal_salt_1_offset);
    std.debug.assert(header_wal_salt_1_offset + 4 == header_wal_salt_2_offset);
    std.debug.assert(header_wal_salt_2_offset + 4 == header_node_id_offset);
    std.debug.assert(header_node_id_offset + 8 == header_reserved_offset);
    std.debug.assert(header_reserved_offset + header_reserved_size == header_size);
    std.debug.assert(page_header_flags_offset + 2 == page_header_size);
    std.debug.assert(sqlite_page_size_max == 65_536);
    std.debug.assert(std.math.isPowerOfTwo(sqlite_page_size_min));
    std.debug.assert(std.math.isPowerOfTwo(sqlite_page_size_max));
}

test "header wire layout is canonical and reserved bytes are zero" {
    const limits = Limits{
        .max_input_bytes = 1_000_000,
        .max_output_bytes = 1_000_000,
        .max_pages = 10,
        .max_page_size = 65_536,
        .max_compressed_page_size = 66_000,
        .max_page_index_bytes = 1_000,
        .max_page_index_entries = 10,
        .max_varint_bytes = 10,
        .max_transaction_span = 10,
    };
    const header = Header{
        .flags = 0,
        .page_size = 4096,
        .commit = 2,
        .min_txid = .init(1),
        .max_txid = .init(2),
        .timestamp_ms = -1,
        .pre_apply_checksum = .init(0),
        .wal_offset = 0,
        .wal_size = 0,
        .wal_salt_1 = 0,
        .wal_salt_2 = 0,
        .node_id = 7,
    };
    try header.validate(limits);
    var bytes: [header_size]u8 = undefined;
    encode_header(header, &bytes);
    try std.testing.expectEqualStrings("LTX1", bytes[0..4]);
    try std.testing.expectEqualSlices(u8, &(@as([20]u8, @splat(0))), bytes[80..100]);
    try std.testing.expectEqualDeep(header, try decode_header(&bytes));

    bytes[80] = 0xa5;
    try std.testing.expectEqualDeep(header, try decode_header(&bytes));
}

test "lock page matches upstream known answers for every SQLite page size" {
    const cases = [_]struct { page_size: u32, lock_page: u32 }{
        .{ .page_size = 512, .lock_page = 2_097_153 },
        .{ .page_size = 1024, .lock_page = 1_048_577 },
        .{ .page_size = 2048, .lock_page = 524_289 },
        .{ .page_size = 4096, .lock_page = 262_145 },
        .{ .page_size = 8192, .lock_page = 131_073 },
        .{ .page_size = 16_384, .lock_page = 65_537 },
        .{ .page_size = 32_768, .lock_page = 32_769 },
        .{ .page_size = 65_536, .lock_page = 16_385 },
    };
    for (cases) |case| {
        try std.testing.expectEqual(case.lock_page, try lock_page_number(case.page_size));
    }
    try std.testing.expectError(error.InvalidPageSize, lock_page_number(0));
    try std.testing.expectError(error.InvalidPageSize, lock_page_number(1000));
}

test "every unknown header and page flag bit is rejected" {
    const limits = Limits{
        .max_input_bytes = 4096,
        .max_output_bytes = 4096,
        .max_pages = 1,
        .max_page_size = 512,
        .max_compressed_page_size = 515,
        .max_page_index_bytes = 32,
        .max_page_index_entries = 1,
        .max_varint_bytes = 10,
        .max_transaction_span = 1,
    };
    const base = Header{
        .flags = 0,
        .page_size = 512,
        .commit = 0,
        .min_txid = .init(1),
        .max_txid = .init(1),
        .timestamp_ms = 0,
        .pre_apply_checksum = .init(0),
        .wal_offset = 0,
        .wal_size = 0,
        .wal_salt_1 = 0,
        .wal_salt_2 = 0,
        .node_id = 0,
    };
    var bit: u6 = 0;
    while (bit < 32) : (bit += 1) {
        const flag = @as(u32, 1) << @intCast(bit);
        if (flag == header_flag_no_checksum) continue;
        var header = base;
        header.flags = flag;
        try std.testing.expectError(error.InvalidHeaderFlags, header.validate(limits));
    }

    var page_bit: u5 = 1;
    while (page_bit < 16) : (page_bit += 1) {
        const header = PageHeader{
            .page_number = 1,
            .flags = @as(u16, 1) << @intCast(page_bit),
        };
        try std.testing.expectError(error.InvalidPageFlags, header.validate());
    }
}
