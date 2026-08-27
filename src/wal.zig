//! SQLite WAL parsing for LTX capture.
//!
//! Ported from the pinned `denoland/celld` LTX crate `wal.rs` at commit
//! `89e4ffc53a14ecb496d2ca5014ff9d19b0061ad9`, which ports Litestream
//! v0.5.11 `wal_reader.go`. The reader validates the 32-byte WAL header,
//! frame salts, and the cumulative SQLite checksum chain while borrowing page
//! bytes directly from the caller's slice, so no page buffer or copy is
//! needed.
//!
//! Go collapses every end-of-valid-region condition into `io.EOF`. This port
//! keeps the same terminal behavior but reports the cause: a clean end, a torn
//! frame, a frame belonging to a later segment (salt mismatch), or a broken
//! checksum chain. Scans treat all four as the end of the valid region.
//!
//! This module is standalone: it imports only the standard library, performs
//! no allocation, and accepts hostile input. It does not enforce transaction
//! boundaries itself; `page_map` is the operation that honors commit records.

const std = @import("std");

pub const header_size_bytes: usize = 32;
pub const frame_header_size_bytes: usize = 24;
/// The only WAL format version, found at header offset 4.
pub const format_version: u32 = 3_007_000;
/// Magic at header offset 0 selecting little-endian checksum words.
pub const magic_little_endian: u32 = 0x377f_0682;
/// Magic at header offset 0 selecting big-endian checksum words.
pub const magic_big_endian: u32 = 0x377f_0683;
pub const page_size_min: u32 = 512;
pub const page_size_max: u32 = 65_536;

pub const Error = error{
    InvalidLimits,
    WorkspaceTooSmall,
    WorkspaceAliasing,
    InvalidMagic,
    UnsupportedVersion,
    InvalidPageSize,
    PageSizeLimitExceeded,
    TruncatedHeader,
    HeaderChecksumMismatch,
    WalEnd,
    TruncatedFrame,
    SaltMismatch,
    FrameChecksumMismatch,
    InvalidPageNumber,
    PageLimitExceeded,
    FrameLimitExceeded,
    SaltLimitExceeded,
    InvalidOffset,
    PreviousFrameMismatch,
    InvalidState,
};

/// Byte order of the 32-bit words fed to the cumulative checksum, selected by
/// the WAL magic. Header and frame scalar fields are always big-endian.
pub const ChecksumOrder = enum { little, big };

pub const ChecksumPair = struct { sum_1: u32, sum_2: u32 };

/// Computes the running SQLite WAL checksum over `bytes`, whose length must
/// be a multiple of eight. Feed the first 24 header bytes from zero, then each
/// frame's 8-byte header prefix and page data, threading the result through.
pub fn checksum(
    order: ChecksumOrder,
    prior: ChecksumPair,
    bytes: []const u8,
) ChecksumPair {
    std.debug.assert(bytes.len % 8 == 0);
    var sums = prior;
    var index: usize = 0;
    while (index < bytes.len) : (index += 8) {
        const chunk = bytes[index..][0..8];
        const first = switch (order) {
            .little => std.mem.readInt(u32, chunk[0..4], .little),
            .big => std.mem.readInt(u32, chunk[0..4], .big),
        };
        const second = switch (order) {
            .little => std.mem.readInt(u32, chunk[4..8], .little),
            .big => std.mem.readInt(u32, chunk[4..8], .big),
        };
        sums.sum_1 = sums.sum_1 +% first +% sums.sum_2;
        sums.sum_2 = sums.sum_2 +% second +% sums.sum_1;
    }
    return sums;
}

pub const SaltPair = struct { salt_1: u32, salt_2: u32 };

pub const Header = struct {
    checksum_order: ChecksumOrder,
    version: u32,
    page_size: u32,
    checkpoint_sequence: u32,
    salt_1: u32,
    salt_2: u32,
    checksum_1: u32,
    checksum_2: u32,
};

pub fn is_valid_page_size(page_size: u32) bool {
    return page_size >= page_size_min and
        page_size <= page_size_max and
        std.math.isPowerOfTwo(page_size);
}

/// Decodes and validates the fixed 32-byte header. The stored checksum covers
/// bytes 0 through 23; the version must be exactly `format_version`; page size
/// must be a SQLite power-of-two size.
pub fn decode_header(source: *const [header_size_bytes]u8) Error!Header {
    const magic = std.mem.readInt(u32, source[0..4], .big);
    const order: ChecksumOrder = switch (magic) {
        magic_little_endian => .little,
        magic_big_endian => .big,
        else => return error.InvalidMagic,
    };
    const checksum_1 = std.mem.readInt(u32, source[24..28], .big);
    const checksum_2 = std.mem.readInt(u32, source[28..32], .big);
    const computed = checksum(order, .{ .sum_1 = 0, .sum_2 = 0 }, source[0..24]);
    if (computed.sum_1 != checksum_1 or computed.sum_2 != checksum_2) {
        return error.HeaderChecksumMismatch;
    }
    const header = Header{
        .checksum_order = order,
        .version = std.mem.readInt(u32, source[4..8], .big),
        .page_size = std.mem.readInt(u32, source[8..12], .big),
        .checkpoint_sequence = std.mem.readInt(u32, source[12..16], .big),
        .salt_1 = std.mem.readInt(u32, source[16..20], .big),
        .salt_2 = std.mem.readInt(u32, source[20..24], .big),
        .checksum_1 = checksum_1,
        .checksum_2 = checksum_2,
    };
    if (header.version != format_version) return error.UnsupportedVersion;
    if (!is_valid_page_size(header.page_size)) return error.InvalidPageSize;
    return header;
}

const FrameHeader = struct {
    page_number: u32,
    commit_pages: u32,
    salt_1: u32,
    salt_2: u32,
    checksum_1: u32,
    checksum_2: u32,
};

fn decode_frame_header(source: *const [frame_header_size_bytes]u8) FrameHeader {
    return .{
        .page_number = std.mem.readInt(u32, source[0..4], .big),
        .commit_pages = std.mem.readInt(u32, source[4..8], .big),
        .salt_1 = std.mem.readInt(u32, source[8..12], .big),
        .salt_2 = std.mem.readInt(u32, source[12..16], .big),
        .checksum_1 = std.mem.readInt(u32, source[16..20], .big),
        .checksum_2 = std.mem.readInt(u32, source[20..24], .big),
    };
}

pub const Frame = struct {
    page_number: u32,
    /// Database size in pages when this frame commits a transaction; zero for
    /// non-commit frames.
    commit_pages: u32,
    /// Byte offset of this frame's header within the input slice.
    offset_bytes: u64,
    /// Page bytes borrowed from the reader's input slice; the next successful
    /// read renders a previously returned slice stale.
    data: []const u8,
};

/// Why frame reading stopped. Go reports all of these as one `io.EOF`.
pub const Stop = union(enum) {
    /// The next frame would begin exactly at the end of the input.
    end_of_input,
    /// A partial frame header or page body remains; a torn write.
    truncated_frame,
    /// The frame belongs to a different WAL segment.
    salt_mismatch: SaltPair,
    /// The cumulative checksum chain broke at this frame.
    checksum_mismatch,
};

pub const Limits = struct {
    /// Largest accepted WAL page size; itself a valid SQLite page size.
    max_page_size: u32,
    /// Largest accepted page number; sizes the page-map workspaces.
    max_pages: u32,
    /// Largest number of frames one scan operation may read. The bound must
    /// cover every frame in the input, including bytes of any torn tail.
    max_frames: u32,

    pub fn validate(self: Limits) error{InvalidLimits}!void {
        if (!is_valid_page_size(self.max_page_size)) return error.InvalidLimits;
        if (self.max_pages == 0) return error.InvalidLimits;
        if (self.max_frames == 0) return error.InvalidLimits;
    }
};

pub const PageMapEntry = struct {
    page_number: u32,
    /// Byte offset of the frame holding the latest committed version.
    frame_offset_bytes: u64,
};

/// Latest in-transaction and latest committed frame offset for one page.
pub const PageSlot = struct {
    committed_offset_bytes: u64 = 0,
    pending_offset_bytes: u64 = 0,
};

pub const PageMap = struct {
    /// Committed pages in ascending page-number order, excluding pages beyond
    /// the final commit.
    pages: []const PageMapEntry,
    /// Final committed database size in pages; zero when no transaction
    /// committed within the valid region.
    commit_pages: u32,
    /// End offset of the last committed frame; zero when no transaction
    /// committed within the valid region.
    end_offset_bytes: u64,
    /// Frames read before the scan stopped.
    frame_count: u64,
    /// Why frame reading stopped.
    stop: Stop,
};

/// Caller-owned page-map scratch. Contents may be undefined at the call; all
/// mutable ranges must be address-stable, exclusive, and mutually
/// non-overlapping.
pub const PageMapWorkspace = struct {
    /// At least `Limits.max_pages` slots.
    slots: []PageSlot,
    /// At least `Limits.max_pages` page numbers.
    pending_pages: []u32,
    /// At least `(Limits.max_pages + 7) / 8` bitmap bytes.
    pending_seen: []u8,
    /// At least `Limits.max_pages` result entries.
    entries: []PageMapEntry,
};

/// Reads and verifies WAL frames from a caller-owned byte slice.
///
/// This is a stateful, single-owner value: do not copy it after
/// initialization. Terminal stops are recorded and repeat identically on
/// later `read_frame` calls; `page_map` is one-shot.
pub const Reader = struct {
    bytes: []const u8,
    limits: Limits,
    header_value: Header,
    /// Effective segment salts: the header salts, or caller-supplied values
    /// when resuming mid-WAL.
    salt: SaltPair,
    /// Zero-based index of the next frame to read.
    frame_index: u64,
    sums: ChecksumPair,
    stop: ?Stop = null,

    pub fn init(limits: Limits, bytes: []const u8) Error!Reader {
        limits.validate() catch return error.InvalidLimits;
        if (bytes.len < header_size_bytes) return error.TruncatedHeader;
        const header_value = try decode_header(bytes[0..header_size_bytes]);
        if (header_value.page_size > limits.max_page_size) {
            return error.PageSizeLimitExceeded;
        }
        return .{
            .bytes = bytes,
            .limits = limits,
            .header_value = header_value,
            .salt = .{ .salt_1 = header_value.salt_1, .salt_2 = header_value.salt_2 },
            .frame_index = 0,
            .sums = .{ .sum_1 = header_value.checksum_1, .sum_2 = header_value.checksum_2 },
        };
    }

    /// Creates a reader resuming at the frame boundary `offset_bytes`, seeding
    /// the cumulative checksum from the previous frame without verifying the
    /// chain from the beginning. `salt` holds the expected salts of the
    /// resumed segment and overrides the header salts, which may have been
    /// rewritten after a checkpoint restart.
    pub fn init_with_offset(
        limits: Limits,
        bytes: []const u8,
        offset_bytes: u64,
        salt: SaltPair,
    ) Error!Reader {
        var self = try init(limits, bytes);
        if (offset_bytes <= header_size_bytes) return error.InvalidOffset;
        const relative = offset_bytes - header_size_bytes;
        if (relative % self.frame_size_bytes() != 0) return error.InvalidOffset;
        const index = relative / self.frame_size_bytes();
        if (index == 0) return error.InvalidOffset;
        self.salt = salt;
        self.frame_index = index - 1;
        try self.seed_previous_frame();
        return self;
    }

    pub fn header(self: *const Reader) Header {
        return self.header_value;
    }

    pub fn page_size_bytes(self: *const Reader) u32 {
        return self.header_value.page_size;
    }

    pub fn frame_size_bytes(self: *const Reader) u64 {
        return @as(u64, frame_header_size_bytes) +
            @as(u64, self.header_value.page_size);
    }

    /// The recorded stop, if reading has terminated.
    pub fn stop_reason(self: *const Reader) ?Stop {
        return self.stop;
    }

    /// Reads and validates the next frame, returning its header fields and a
    /// page slice borrowed from the input. Terminal results (`WalEnd`,
    /// `TruncatedFrame`, `SaltMismatch`, `FrameChecksumMismatch`) are recorded
    /// and returned again by later calls.
    pub fn read_frame(self: *Reader) Error!Frame {
        if (self.stop != null) return self.stop_error();
        return self.read_frame_internal();
    }

    /// Scans frames to the end of the valid region and builds the committed
    /// page map: the latest committed frame offset of every page, in
    /// ascending page order, excluding pages beyond the final commit.
    /// Uncommitted trailing frames are discarded and every stop condition
    /// ends the scan successfully. One-shot: rejects a reader that already
    /// stopped.
    pub fn page_map(self: *Reader, workspace: PageMapWorkspace) Error!PageMap {
        if (self.stop != null) return error.InvalidState;
        try validate_page_map_workspace(self.limits, workspace);
        var scan = PageMapScan{ .reader = self, .workspace = workspace };
        return scan.run();
    }

    /// Collects the distinct frame salt pairs of the whole file in first-seen
    /// order, stopping after `until` when a frame carries it. Checksums and
    /// header-salt agreement are deliberately not checked, so salts of
    /// superseded transactions are included. `out` bounds the distinct-pair
    /// count.
    pub fn frame_salts_until(
        self: *const Reader,
        until: SaltPair,
        out: []SaltPair,
    ) Error![]const SaltPair {
        var count: usize = 0;
        var frame_index: u64 = 0;
        var terminated = false;
        while (frame_index < self.limits.max_frames) : (frame_index += 1) {
            const offset = self.frame_offset(frame_index) catch
                return error.FrameLimitExceeded;
            const header_end = std.math.add(u64, offset, frame_header_size_bytes) catch
                return error.FrameLimitExceeded;
            if (header_end > self.bytes.len) {
                terminated = true;
                break;
            }
            const header_offset: usize = @intCast(offset);
            const frame_header = decode_frame_header(
                self.bytes[header_offset..][0..frame_header_size_bytes],
            );
            const pair = SaltPair{
                .salt_1 = frame_header.salt_1,
                .salt_2 = frame_header.salt_2,
            };
            try append_salt_unique(out, &count, pair);
            if (std.meta.eql(pair, until)) {
                terminated = true;
                break;
            }
        }
        if (!terminated and frame_index == self.limits.max_frames) {
            return error.FrameLimitExceeded;
        }
        return out[0..count];
    }

    fn stop_error(self: *const Reader) Error {
        return switch (self.stop.?) {
            .end_of_input => error.WalEnd,
            .truncated_frame => error.TruncatedFrame,
            .salt_mismatch => error.SaltMismatch,
            .checksum_mismatch => error.FrameChecksumMismatch,
        };
    }

    fn seed_previous_frame(self: *Reader) Error!void {
        const offset = self.frame_offset(self.frame_index) catch
            return error.PreviousFrameMismatch;
        const header_end = std.math.add(u64, offset, frame_header_size_bytes) catch
            return error.PreviousFrameMismatch;
        const page_end = std.math.add(u64, header_end, self.header_value.page_size) catch
            return error.PreviousFrameMismatch;
        if (page_end > self.bytes.len) return error.PreviousFrameMismatch;
        const header_offset: usize = @intCast(offset);
        const frame_header = decode_frame_header(
            self.bytes[header_offset..][0..frame_header_size_bytes],
        );
        if (frame_header.salt_1 != self.salt.salt_1 or
            frame_header.salt_2 != self.salt.salt_2)
        {
            return error.PreviousFrameMismatch;
        }
        // Adopt the stored cumulative checksum; verification started earlier.
        self.sums = .{
            .sum_1 = frame_header.checksum_1,
            .sum_2 = frame_header.checksum_2,
        };
        self.frame_index += 1;
    }

    fn read_frame_internal(self: *Reader) Error!Frame {
        const offset = try self.frame_offset(self.frame_index);
        if (offset == self.bytes.len) {
            self.stop = .end_of_input;
            return error.WalEnd;
        }
        const header_end = std.math.add(u64, offset, frame_header_size_bytes) catch
            return error.FrameLimitExceeded;
        if (header_end > self.bytes.len) {
            self.stop = .truncated_frame;
            return error.TruncatedFrame;
        }
        const page_end = std.math.add(u64, header_end, self.header_value.page_size) catch
            return error.FrameLimitExceeded;
        if (page_end > self.bytes.len) {
            self.stop = .truncated_frame;
            return error.TruncatedFrame;
        }
        const header_offset: usize = @intCast(offset);
        const page_offset: usize = @intCast(header_end);
        const frame_header = decode_frame_header(
            self.bytes[header_offset..][0..frame_header_size_bytes],
        );
        const page = self.bytes[page_offset..@intCast(page_end)];
        if (frame_header.salt_1 != self.salt.salt_1 or
            frame_header.salt_2 != self.salt.salt_2)
        {
            self.stop = .{
                .salt_mismatch = .{
                    .salt_1 = frame_header.salt_1,
                    .salt_2 = frame_header.salt_2,
                },
            };
            return error.SaltMismatch;
        }
        var sums = checksum(
            self.header_value.checksum_order,
            self.sums,
            self.bytes[header_offset..][0..8],
        );
        sums = checksum(self.header_value.checksum_order, sums, page);
        if (sums.sum_1 != frame_header.checksum_1 or
            sums.sum_2 != frame_header.checksum_2)
        {
            self.stop = .checksum_mismatch;
            return error.FrameChecksumMismatch;
        }
        self.sums = sums;
        self.frame_index += 1;
        return .{
            .page_number = frame_header.page_number,
            .commit_pages = frame_header.commit_pages,
            .offset_bytes = offset,
            .data = page,
        };
    }

    fn frame_offset(self: *const Reader, index: u64) Error!u64 {
        const relative = std.math.mul(u64, index, self.frame_size_bytes()) catch
            return error.FrameLimitExceeded;
        return std.math.add(u64, header_size_bytes, relative) catch
            return error.FrameLimitExceeded;
    }
};

const PageMapScan = struct {
    reader: *Reader,
    workspace: PageMapWorkspace,
    commit_pages: u32 = 0,
    end_offset_bytes: u64 = 0,
    frame_count: u64 = 0,
    pending_count: u32 = 0,

    fn run(scan: *PageMapScan) Error!PageMap {
        @memset(scan.workspace.slots, .{});
        @memset(scan.workspace.pending_seen, 0);
        while (scan.frame_count < scan.reader.limits.max_frames) {
            const frame = scan.reader.read_frame() catch |err| switch (err) {
                error.WalEnd,
                error.TruncatedFrame,
                error.SaltMismatch,
                error.FrameChecksumMismatch,
                => break,
                else => return err,
            };
            scan.frame_count += 1;
            try scan.record_frame(frame);
        }
        if (scan.reader.stop == null) {
            const next_offset = try scan.reader.frame_offset(scan.reader.frame_index);
            if (next_offset == scan.reader.bytes.len) {
                scan.reader.stop = .end_of_input;
            } else {
                return error.FrameLimitExceeded;
            }
        }
        return scan.finish();
    }

    fn record_frame(scan: *PageMapScan, frame: Frame) Error!void {
        if (frame.page_number == 0) return error.InvalidPageNumber;
        if (frame.page_number > scan.reader.limits.max_pages) {
            return error.PageLimitExceeded;
        }
        const slot = &scan.workspace.slots[frame.page_number - 1];
        const seen_index = frame.page_number - 1;
        const seen_mask = @as(u8, 1) << @intCast(seen_index % 8);
        if (scan.workspace.pending_seen[seen_index / 8] & seen_mask == 0) {
            scan.workspace.pending_seen[seen_index / 8] |= seen_mask;
            const pending_index = scan.pending_count;
            scan.pending_count += 1;
            scan.workspace.pending_pages[pending_index] = frame.page_number;
        }
        slot.pending_offset_bytes = frame.offset_bytes;
        if (frame.commit_pages == 0) return;
        try scan.promote_pending();
        scan.commit_pages = frame.commit_pages;
    }

    /// Transfers the current transaction's offsets into the committed map and
    /// clears its pending set. The commit frame itself is already recorded as
    /// pending, so promotion includes it.
    fn promote_pending(scan: *PageMapScan) Error!void {
        var pending_index: u32 = 0;
        while (pending_index < scan.pending_count) : (pending_index += 1) {
            const page_number = scan.workspace.pending_pages[pending_index];
            const slot = &scan.workspace.slots[page_number - 1];
            slot.committed_offset_bytes = slot.pending_offset_bytes;
            slot.pending_offset_bytes = 0;
            const seen_index = page_number - 1;
            scan.workspace.pending_seen[seen_index / 8] &=
                ~(@as(u8, 1) << @intCast(seen_index % 8));
            const frame_end = std.math.add(
                u64,
                slot.committed_offset_bytes,
                scan.reader.frame_size_bytes(),
            ) catch return error.FrameLimitExceeded;
            if (frame_end > scan.end_offset_bytes) {
                scan.end_offset_bytes = frame_end;
            }
        }
        scan.pending_count = 0;
    }

    fn finish(scan: *PageMapScan) Error!PageMap {
        const stop = scan.reader.stop orelse return error.InvalidState;
        const page_bound = @min(scan.commit_pages, scan.reader.limits.max_pages);
        var count: u32 = 0;
        var page_number: u32 = 1;
        while (page_number <= page_bound) : (page_number += 1) {
            const slot = scan.workspace.slots[page_number - 1];
            if (slot.committed_offset_bytes == 0) continue;
            scan.workspace.entries[count] = .{
                .page_number = page_number,
                .frame_offset_bytes = slot.committed_offset_bytes,
            };
            count += 1;
        }
        if (count == 0) {
            return .{
                .pages = scan.workspace.entries[0..0],
                .commit_pages = 0,
                .end_offset_bytes = 0,
                .frame_count = scan.frame_count,
                .stop = stop,
            };
        }
        return .{
            .pages = scan.workspace.entries[0..count],
            .commit_pages = scan.commit_pages,
            .end_offset_bytes = scan.end_offset_bytes,
            .frame_count = scan.frame_count,
            .stop = stop,
        };
    }
};

fn append_salt_unique(out: []SaltPair, count: *usize, pair: SaltPair) Error!void {
    var index: usize = 0;
    while (index < count.*) : (index += 1) {
        if (std.meta.eql(out[index], pair)) return;
    }
    if (count.* == out.len) return error.SaltLimitExceeded;
    out[count.*] = pair;
    count.* += 1;
}

fn validate_page_map_workspace(limits: Limits, workspace: PageMapWorkspace) Error!void {
    const pages = std.math.cast(usize, limits.max_pages) orelse
        return error.InvalidLimits;
    const bitmap = (pages + 7) / 8;
    if (workspace.slots.len < pages) return error.WorkspaceTooSmall;
    if (workspace.pending_pages.len < pages) return error.WorkspaceTooSmall;
    if (workspace.pending_seen.len < bitmap) return error.WorkspaceTooSmall;
    if (workspace.entries.len < pages) return error.WorkspaceTooSmall;
    const slot_bytes = std.mem.sliceAsBytes(workspace.slots);
    const pending_bytes = std.mem.sliceAsBytes(workspace.pending_pages);
    const entry_bytes = std.mem.sliceAsBytes(workspace.entries);
    if (slices_overlap(slot_bytes, pending_bytes) or
        slices_overlap(slot_bytes, workspace.pending_seen) or
        slices_overlap(slot_bytes, entry_bytes) or
        slices_overlap(pending_bytes, workspace.pending_seen) or
        slices_overlap(pending_bytes, entry_bytes) or
        slices_overlap(workspace.pending_seen, entry_bytes))
    {
        return error.WorkspaceAliasing;
    }
}

fn slices_overlap(left: []const u8, right: []const u8) bool {
    if (left.len == 0 or right.len == 0) return false;
    const left_start = @intFromPtr(left.ptr);
    const right_start = @intFromPtr(right.ptr);
    const left_end = std.math.add(usize, left_start, left.len) catch unreachable;
    const right_end = std.math.add(usize, right_start, right.len) catch unreachable;
    return left_start < right_end and right_start < left_end;
}

const TestFrame = struct {
    page_number: u32,
    commit_pages: u32,
    salt: ?SaltPair,
    fill: u8,
};

/// Builds a synthetic WAL with a valid checksum chain. Structural coverage
/// lives here; wire-level known answers come from the pinned fixtures.
fn build_test_wal(
    destination: []u8,
    order: ChecksumOrder,
    salt: SaltPair,
    frames: []const TestFrame,
) []const u8 {
    const page_size = page_size_min;
    std.mem.writeInt(u32, destination[0..4], switch (order) {
        .little => magic_little_endian,
        .big => magic_big_endian,
    }, .big);
    std.mem.writeInt(u32, destination[4..8], format_version, .big);
    std.mem.writeInt(u32, destination[8..12], page_size, .big);
    std.mem.writeInt(u32, destination[12..16], 0, .big);
    std.mem.writeInt(u32, destination[16..20], salt.salt_1, .big);
    std.mem.writeInt(u32, destination[20..24], salt.salt_2, .big);
    const header_sums = checksum(order, .{ .sum_1 = 0, .sum_2 = 0 }, destination[0..24]);
    std.mem.writeInt(u32, destination[24..28], header_sums.sum_1, .big);
    std.mem.writeInt(u32, destination[28..32], header_sums.sum_2, .big);

    var sums = header_sums;
    var offset: usize = header_size_bytes;
    for (frames) |test_frame| {
        const frame_salt = test_frame.salt orelse salt;
        @memset(destination[offset..][0..frame_header_size_bytes], 0);
        std.mem.writeInt(u32, destination[offset..][0..4], test_frame.page_number, .big);
        std.mem.writeInt(u32, destination[offset..][4..8], test_frame.commit_pages, .big);
        std.mem.writeInt(u32, destination[offset..][8..12], frame_salt.salt_1, .big);
        std.mem.writeInt(u32, destination[offset..][12..16], frame_salt.salt_2, .big);
        sums = checksum(order, sums, destination[offset..][0..8]);
        const page = destination[offset + frame_header_size_bytes ..][0..page_size];
        @memset(page, test_frame.fill);
        sums = checksum(order, sums, page);
        std.mem.writeInt(u32, destination[offset + 16 ..][0..4], sums.sum_1, .big);
        std.mem.writeInt(u32, destination[offset + 20 ..][0..4], sums.sum_2, .big);
        offset += frame_header_size_bytes + page_size;
    }
    return destination[0..offset];
}

const test_limits = Limits{
    .max_page_size = page_size_max,
    .max_pages = 8,
    .max_frames = 16,
};

const TestWorkspaces = struct {
    slots: [test_limits.max_pages]PageSlot = [_]PageSlot{.{}} ** test_limits.max_pages,
    pending: [test_limits.max_pages]u32 = [_]u32{0} ** test_limits.max_pages,
    seen: [(test_limits.max_pages + 7) / 8]u8 = [_]u8{0} ** ((test_limits.max_pages + 7) / 8),
    entries: [test_limits.max_pages]PageMapEntry =
        [_]PageMapEntry{.{ .page_number = 0, .frame_offset_bytes = 0 }} **
        test_limits.max_pages,

    fn workspace(self: *TestWorkspaces) PageMapWorkspace {
        return .{
            .slots = &self.slots,
            .pending_pages = &self.pending,
            .pending_seen = &self.seen,
            .entries = &self.entries,
        };
    }
};

test "wal checksum matches the Go bad-version header vector" {
    // Bytes 0..24 and the stored checksum come from Litestream's
    // TestWALReader/BadHeaderVersion; the checksum field is a Go known answer.
    const source = [32]u8{
        0x37, 0x7f, 0x06, 0x83, 0x00, 0x00, 0x00, 0x01, //
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, //
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, //
        0x15, 0x7b, 0x20, 0x92, 0xbb, 0xf8, 0x34, 0x1d,
    };
    const sums = checksum(.big, .{ .sum_1 = 0, .sum_2 = 0 }, source[0..24]);
    try std.testing.expectEqual(@as(u32, 0x157b_2092), sums.sum_1);
    try std.testing.expectEqual(@as(u32, 0xbbf8_341d), sums.sum_2);
    try std.testing.expectError(error.UnsupportedVersion, decode_header(&source));
}

test "header validation rejects each malformed shape" {
    try std.testing.expectError(error.TruncatedHeader, init_reader(&.{}));
    try std.testing.expectError(error.TruncatedHeader, init_reader(&[_]u8{0} ** 10));
    try std.testing.expectError(error.InvalidMagic, init_reader(&[_]u8{0} ** 32));
    const bad_checksum = [32]u8{
        0x37, 0x7f, 0x06, 0x83, 0x00, 0x00, 0x00, 0x00, //
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, //
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, //
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    };
    try std.testing.expectError(error.HeaderChecksumMismatch, init_reader(&bad_checksum));

    var storage: [4096]u8 = undefined;
    const wal_bytes = build_test_wal(
        &storage,
        .little,
        .{ .salt_1 = 0x1111, .salt_2 = 0x2222 },
        &.{},
    );
    var reader = try init_reader(wal_bytes);
    try std.testing.expectEqual(@as(u32, page_size_min), reader.page_size_bytes());
    try std.testing.expectError(error.WalEnd, reader.read_frame());
    // The recorded stop repeats on every later call.
    try std.testing.expectError(error.WalEnd, reader.read_frame());
    try std.testing.expectEqual(Stop.end_of_input, reader.stop_reason().?);

    const too_small = Limits{ .max_page_size = 256, .max_pages = 1, .max_frames = 1 };
    try std.testing.expectError(error.InvalidLimits, Reader.init(too_small, wal_bytes));
}

fn init_reader(bytes: []const u8) Error!Reader {
    return Reader.init(test_limits, bytes);
}

test "read_frame verifies frames and borrows page data" {
    var storage: [4096]u8 = undefined;
    const salt = SaltPair{ .salt_1 = 0x0102_0304, .salt_2 = 0x0506_0708 };
    const wal_bytes = build_test_wal(&storage, .little, salt, &.{
        .{ .page_number = 1, .commit_pages = 0, .salt = null, .fill = 0xa1 },
        .{ .page_number = 2, .commit_pages = 2, .salt = null, .fill = 0xb2 },
        .{ .page_number = 2, .commit_pages = 2, .salt = null, .fill = 0xc3 },
    });
    var reader = try init_reader(wal_bytes);

    const frame_size = frame_header_size_bytes + page_size_min;
    const first = try reader.read_frame();
    try std.testing.expectEqual(@as(u32, 1), first.page_number);
    try std.testing.expectEqual(@as(u32, 0), first.commit_pages);
    try std.testing.expectEqual(@as(u64, header_size_bytes), first.offset_bytes);
    try std.testing.expectEqual(@as(u8, 0xa1), first.data[0]);
    const second = try reader.read_frame();
    try std.testing.expectEqual(@as(u32, 2), second.page_number);
    try std.testing.expectEqual(@as(u32, 2), second.commit_pages);
    try std.testing.expectEqual(@as(u64, header_size_bytes + frame_size), second.offset_bytes);
    const third = try reader.read_frame();
    try std.testing.expectEqual(@as(u8, 0xc3), third.data[0]);
    try std.testing.expectError(error.WalEnd, reader.read_frame());
}

test "terminal stops distinguish salt mismatch, torn frames, and checksums" {
    const salt = SaltPair{ .salt_1 = 1, .salt_2 = 2 };
    const other_salt = SaltPair{ .salt_1 = 3, .salt_2 = 4 };
    var storage: [4096]u8 = undefined;

    const salted_bytes = build_test_wal(&storage, .big, salt, &.{
        .{ .page_number = 1, .commit_pages = 0, .salt = null, .fill = 0x11 },
        .{ .page_number = 2, .commit_pages = 2, .salt = other_salt, .fill = 0x22 },
    });
    var salted = try init_reader(salted_bytes);
    _ = try salted.read_frame();
    try std.testing.expectError(error.SaltMismatch, salted.read_frame());
    try std.testing.expectEqual(
        Stop{ .salt_mismatch = other_salt },
        salted.stop_reason().?,
    );

    const whole_bytes = build_test_wal(&storage, .big, salt, &.{
        .{ .page_number = 1, .commit_pages = 1, .salt = null, .fill = 0x33 },
    });
    var torn_reader = try init_reader(whole_bytes[0 .. whole_bytes.len - 1]);
    try std.testing.expectError(error.TruncatedFrame, torn_reader.read_frame());
    try std.testing.expectEqual(Stop.truncated_frame, torn_reader.stop_reason().?);

    var mutable_storage: [8192]u8 = undefined;
    _ = build_test_wal(&mutable_storage, .little, salt, &.{
        .{ .page_number = 1, .commit_pages = 0, .salt = null, .fill = 0x44 },
        .{ .page_number = 2, .commit_pages = 2, .salt = null, .fill = 0x55 },
    });
    const page_two_offset = header_size_bytes +
        frame_header_size_bytes + page_size_min + frame_header_size_bytes;
    mutable_storage[page_two_offset] ^= 0x80;
    var flipped = try init_reader(&mutable_storage);
    _ = try flipped.read_frame();
    try std.testing.expectError(error.FrameChecksumMismatch, flipped.read_frame());
    try std.testing.expectEqual(Stop.checksum_mismatch, flipped.stop_reason().?);
}

test "page_map promotes only committed transactions with newest pages" {
    const salt = SaltPair{ .salt_1 = 7, .salt_2 = 8 };
    const frame_size = frame_header_size_bytes + page_size_min;
    var storage: [16_384]u8 = undefined;

    // Two committed transactions plus an uncommitted trailing frame: page 3
    // must be absent, page 1 keeps its first-commit offset, page 2 its latest.
    const wal_bytes = build_test_wal(&storage, .little, salt, &.{
        .{ .page_number = 1, .commit_pages = 0, .salt = null, .fill = 0x01 },
        .{ .page_number = 2, .commit_pages = 2, .salt = null, .fill = 0x02 },
        .{ .page_number = 2, .commit_pages = 0, .salt = null, .fill = 0x12 },
        .{ .page_number = 2, .commit_pages = 2, .salt = null, .fill = 0x22 },
        .{ .page_number = 3, .commit_pages = 0, .salt = null, .fill = 0x03 },
    });
    var reader = try init_reader(wal_bytes);
    var workspaces = TestWorkspaces{};
    const map = try reader.page_map(workspaces.workspace());
    try std.testing.expectEqual(@as(u32, 2), map.commit_pages);
    try std.testing.expectEqual(@as(u64, 5), map.frame_count);
    try std.testing.expectEqual(Stop.end_of_input, map.stop);
    try std.testing.expectEqual(@as(usize, 2), map.pages.len);
    try std.testing.expectEqual(@as(u32, 1), map.pages[0].page_number);
    try std.testing.expectEqual(
        @as(u64, header_size_bytes),
        map.pages[0].frame_offset_bytes,
    );
    try std.testing.expectEqual(@as(u32, 2), map.pages[1].page_number);
    try std.testing.expectEqual(
        @as(u64, header_size_bytes + 3 * frame_size),
        map.pages[1].frame_offset_bytes,
    );
    try std.testing.expectEqual(
        @as(u64, header_size_bytes + 4 * frame_size),
        map.end_offset_bytes,
    );
    // page_map is one-shot on a stopped reader.
    try std.testing.expectError(error.InvalidState, reader.page_map(workspaces.workspace()));

    // A shrink to one page drops page 2 from the committed map.
    var shrink_storage: [8192]u8 = undefined;
    const shrink_bytes = build_test_wal(&shrink_storage, .big, salt, &.{
        .{ .page_number = 1, .commit_pages = 0, .salt = null, .fill = 0x01 },
        .{ .page_number = 2, .commit_pages = 2, .salt = null, .fill = 0x02 },
        .{ .page_number = 1, .commit_pages = 1, .salt = null, .fill = 0x11 },
    });
    var shrink_reader = try init_reader(shrink_bytes);
    var shrink_workspaces = TestWorkspaces{};
    const shrink_map = try shrink_reader.page_map(shrink_workspaces.workspace());
    try std.testing.expectEqual(@as(u32, 1), shrink_map.commit_pages);
    try std.testing.expectEqual(@as(usize, 1), shrink_map.pages.len);
    try std.testing.expectEqual(@as(u32, 1), shrink_map.pages[0].page_number);
}

test "page_map empty region reports zero position" {
    var storage: [4096]u8 = undefined;
    const wal_bytes = build_test_wal(
        &storage,
        .big,
        .{ .salt_1 = 9, .salt_2 = 10 },
        &.{},
    );
    var reader = try init_reader(wal_bytes);
    var workspaces = TestWorkspaces{};
    const map = try reader.page_map(workspaces.workspace());
    try std.testing.expectEqual(@as(usize, 0), map.pages.len);
    try std.testing.expectEqual(@as(u32, 0), map.commit_pages);
    try std.testing.expectEqual(@as(u64, 0), map.end_offset_bytes);
    try std.testing.expectEqual(@as(u64, 0), map.frame_count);
    try std.testing.expectEqual(Stop.end_of_input, map.stop);
}

test "page_map enforces limits and workspace contracts" {
    var storage: [8192]u8 = undefined;
    const wal_bytes = build_test_wal(&storage, .big, .{ .salt_1 = 1, .salt_2 = 1 }, &.{
        .{ .page_number = 1, .commit_pages = 1, .salt = null, .fill = 0 },
        .{ .page_number = 2, .commit_pages = 2, .salt = null, .fill = 0 },
    });

    var bounded = try Reader.init(
        Limits{ .max_page_size = page_size_max, .max_pages = 1, .max_frames = 16 },
        wal_bytes,
    );
    var workspaces = TestWorkspaces{};
    try std.testing.expectError(
        error.PageLimitExceeded,
        bounded.page_map(workspaces.workspace()),
    );

    var frame_bounded = try Reader.init(
        Limits{ .max_page_size = page_size_max, .max_pages = 8, .max_frames = 1 },
        wal_bytes,
    );
    try std.testing.expectError(
        error.FrameLimitExceeded,
        frame_bounded.page_map(workspaces.workspace()),
    );

    // An exact frame budget that ends at the input boundary succeeds.
    var exact = try Reader.init(
        Limits{ .max_page_size = page_size_max, .max_pages = 8, .max_frames = 2 },
        wal_bytes,
    );
    const exact_map = try exact.page_map(workspaces.workspace());
    try std.testing.expectEqual(@as(u64, 2), exact_map.frame_count);
    try std.testing.expectEqual(Stop.end_of_input, exact_map.stop);

    var reader = try init_reader(wal_bytes);
    var small = TestWorkspaces{};
    try std.testing.expectError(
        error.WorkspaceTooSmall,
        reader.page_map(.{
            .slots = small.slots[0 .. test_limits.max_pages - 1],
            .pending_pages = &small.pending,
            .pending_seen = &small.seen,
            .entries = &small.entries,
        }),
    );
    var aliased = TestWorkspaces{};
    const aliased_slots = std.mem.sliceAsBytes(aliased.slots[0..]);
    try std.testing.expectError(
        error.WorkspaceAliasing,
        reader.page_map(.{
            .slots = aliased.slots[0..],
            .pending_pages = std.mem.bytesAsSlice(u32, aliased_slots),
            .pending_seen = &aliased.seen,
            .entries = &aliased.entries,
        }),
    );
}

test "init_with_offset resumes with a seeded checksum" {
    const salt = SaltPair{ .salt_1 = 0x0a0b_0c0d, .salt_2 = 0x0e0f_1011 };
    var storage: [8192]u8 = undefined;
    const wal_bytes = build_test_wal(&storage, .little, salt, &.{
        .{ .page_number = 1, .commit_pages = 1, .salt = null, .fill = 0x71 },
        .{ .page_number = 2, .commit_pages = 2, .salt = null, .fill = 0x72 },
    });
    const frame_size = frame_header_size_bytes + page_size_min;
    const resume_offset: u64 = header_size_bytes + frame_size;

    var reader = try Reader.init_with_offset(
        test_limits,
        wal_bytes,
        resume_offset,
        salt,
    );
    // The resumed frame must still pass the cumulative checksum, proving the
    // previous frame seeded the running sums.
    const frame = try reader.read_frame();
    try std.testing.expectEqual(@as(u32, 2), frame.page_number);
    try std.testing.expectEqual(@as(u8, 0x72), frame.data[0]);
    try std.testing.expectError(error.WalEnd, reader.read_frame());

    try std.testing.expectError(
        error.InvalidOffset,
        Reader.init_with_offset(test_limits, wal_bytes, header_size_bytes, salt),
    );
    try std.testing.expectError(
        error.InvalidOffset,
        Reader.init_with_offset(test_limits, wal_bytes, resume_offset + 1, salt),
    );
    try std.testing.expectError(
        error.PreviousFrameMismatch,
        Reader.init_with_offset(
            test_limits,
            wal_bytes,
            resume_offset,
            .{ .salt_1 = 0xdead_beef, .salt_2 = 0xfeed_face },
        ),
    );
}

test "frame census collects distinct salts through the stop pair" {
    const base = SaltPair{ .salt_1 = 0x1000, .salt_2 = 0x2000 };
    var storage: [16_384]u8 = undefined;
    const wal_bytes = build_test_wal(&storage, .big, base, &.{
        .{ .page_number = 1, .commit_pages = 1, .salt = null, .fill = 0 },
        .{
            .page_number = 1,
            .commit_pages = 1,
            .salt = .{ .salt_1 = 0x3000, .salt_2 = 0x4000 },
            .fill = 0,
        },
        .{
            .page_number = 1,
            .commit_pages = 1,
            .salt = .{ .salt_1 = 0x5000, .salt_2 = 0x6000 },
            .fill = 0,
        },
    });
    var reader = try init_reader(wal_bytes);

    var out: [2]SaltPair = undefined;
    try std.testing.expectError(
        error.SaltLimitExceeded,
        reader.frame_salts_until(.{ .salt_1 = 0, .salt_2 = 0 }, &out),
    );

    var wide: [3]SaltPair = undefined;
    const all = try reader.frame_salts_until(.{ .salt_1 = 0, .salt_2 = 0 }, &wide);
    try std.testing.expectEqual(@as(usize, 3), all.len);
    try std.testing.expectEqual(base.salt_1, all[0].salt_1);
    try std.testing.expectEqual(@as(u32, 0x3000), all[1].salt_1);
    try std.testing.expectEqual(@as(u32, 0x5000), all[2].salt_1);

    var one: [3]SaltPair = undefined;
    const stopped = try reader.frame_salts_until(base, &one);
    try std.testing.expectEqual(@as(usize, 1), stopped.len);
}

test "limits reject configurations that cannot bound work" {
    try (Limits{
        .max_page_size = 4096,
        .max_pages = 1,
        .max_frames = 1,
    }).validate();
    try std.testing.expectError(error.InvalidLimits, (Limits{
        .max_page_size = 4097,
        .max_pages = 1,
        .max_frames = 1,
    }).validate());
    try std.testing.expectError(error.InvalidLimits, (Limits{
        .max_page_size = 4096,
        .max_pages = 0,
        .max_frames = 1,
    }).validate());
    try std.testing.expectError(error.InvalidLimits, (Limits{
        .max_page_size = 4096,
        .max_pages = 1,
        .max_frames = 0,
    }).validate());
}
