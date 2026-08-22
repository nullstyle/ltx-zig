const std = @import("std");
const checksum = @import("checksum.zig");
const format = @import("format.zig");
const lz4_block = @import("lz4_block.zig");
const lz4_frame = @import("lz4_frame.zig");
const page_index = @import("page_index.zig");
const Limits = @import("limits.zig").Limits;
const Reader = @import("transport.zig").Reader;
const wire = @import("wire.zig");
const workspace = @import("workspace.zig");

pub const DecoderState = enum {
    header,
    pages,
    page_index,
    trailer,
    verified,
    failed,
};

pub const DecoderEvent = union(enum) {
    header: format.Header,
    unverified_page: format.UnverifiedPage,
    page_block_complete: void,
    verified: format.VerifiedLTX,
};

pub const Decoder = struct {
    reader: Reader,
    format_version: format.FormatVersion,
    limits: Limits,
    page_workspace: []u8,
    compressed_workspace: []u8,
    index_workspace: []format.PageIndexEntry,
    state: DecoderState = .header,
    header_value: format.Header = undefined,
    file_hasher: checksum.FileHasher = .{},
    snapshot_checksum: format.Checksum = .init(0),
    input_offset_bytes: u64 = 0,
    page_count: u32 = 0,
    previous_page_number: u32 = 0,
    page_index_offset_bytes: u64 = 0,

    pub fn init(
        version: format.FormatVersion,
        limits: Limits,
        reader: Reader,
        page_workspace: []u8,
        compressed_workspace: []u8,
        index_workspace: []format.PageIndexEntry,
    ) format.Error!Decoder {
        try version.validate();
        limits.validate() catch return error.InvalidLimits;
        const page_required = std.math.cast(usize, limits.max_page_size) orelse {
            return error.InvalidLimits;
        };
        const compressed_required = std.math.cast(usize, limits.max_compressed_page_size) orelse {
            return error.InvalidLimits;
        };
        const index_required = std.math.cast(usize, limits.max_page_index_entries) orelse {
            return error.InvalidLimits;
        };
        if (page_workspace.len < page_required) return error.WorkspaceTooSmall;
        if (compressed_workspace.len < compressed_required) return error.WorkspaceTooSmall;
        if (index_workspace.len < index_required) return error.WorkspaceTooSmall;
        const index_bytes = std.mem.sliceAsBytes(index_workspace);
        if (workspace.slices_overlap(page_workspace, compressed_workspace) or
            workspace.slices_overlap(page_workspace, index_bytes) or
            workspace.slices_overlap(compressed_workspace, index_bytes))
        {
            return error.WorkspaceAliasing;
        }
        if (reader.backing_bytes) |backing| {
            if (workspace.slices_overlap(backing, page_workspace) or
                workspace.slices_overlap(backing, compressed_workspace) or
                workspace.slices_overlap(backing, index_bytes))
            {
                return error.WorkspaceAliasing;
            }
        }
        return .{
            .reader = reader,
            .format_version = version,
            .limits = limits,
            .page_workspace = page_workspace,
            .compressed_workspace = compressed_workspace,
            .index_workspace = index_workspace,
        };
    }

    pub fn next(self: *Decoder) format.Error!DecoderEvent {
        if (self.state == .failed or self.state == .verified or self.state == .trailer) {
            return error.InvalidState;
        }
        const event = self.next_internal() catch |err| {
            self.state = .failed;
            return err;
        };
        return event;
    }

    pub fn current_state(self: *const Decoder) DecoderState {
        return self.state;
    }

    pub fn selected_format_version(self: *const Decoder) format.FormatVersion {
        return self.format_version;
    }

    /// Maximum successful events for one complete decode: one header, at most
    /// `max_pages` pages, one page-block boundary, and one verified result.
    pub fn event_budget(self: *const Decoder) u64 {
        return @as(u64, self.limits.max_pages) + 3;
    }

    fn next_internal(self: *Decoder) format.Error!DecoderEvent {
        return switch (self.state) {
            .header => self.decode_header_event(),
            .pages => self.decode_page_event(),
            .page_index => self.decode_terminal_event(),
            .trailer, .verified, .failed => error.InvalidState,
        };
    }

    fn decode_header_event(self: *Decoder) format.Error!DecoderEvent {
        var bytes: [format.header_size]u8 = undefined;
        try self.read_exact(&bytes);
        self.file_hasher.update(&bytes);
        const header = try format.decode_header(&bytes);
        try header.validate(self.limits);

        self.header_value = header;
        if (header.is_snapshot() and !header.no_checksum()) {
            self.snapshot_checksum = checksum.rolling_initial();
        }
        self.state = .pages;
        return .{ .header = header };
    }

    fn decode_page_event(self: *Decoder) format.Error!DecoderEvent {
        const frame_offset_bytes = self.input_offset_bytes;
        var header_bytes: [format.page_header_size]u8 = undefined;
        const header_size_bytes: usize = @intCast(
            try self.format_version.page_header_size_bytes(),
        );
        const encoded_header = header_bytes[0..header_size_bytes];
        try self.read_exact(encoded_header);
        self.file_hasher.update(encoded_header);
        const page_header = switch (self.format_version) {
            .v2 => format.decode_v2_page_header(
                header_bytes[0..format.v2_page_header_size],
            ),
            .v3 => format.decode_page_header(&header_bytes),
            _ => unreachable,
        };

        if (page_header.is_terminator()) {
            try self.validate_snapshot_complete();
            self.page_index_offset_bytes = self.input_offset_bytes;
            self.state = .page_index;
            return .{ .page_block_complete = {} };
        }
        try self.validate_page_header(page_header);
        if (self.format_version == .v3 and
            page_header.flags & format.page_header_flag_size != 0)
        {
            return self.decode_flagged_page(page_header, frame_offset_bytes);
        }
        return self.decode_legacy_page(page_header, frame_offset_bytes);
    }

    fn validate_page_header(self: *Decoder, header: format.PageHeader) format.Error!void {
        try header.validate();
        if (self.page_count >= self.limits.max_pages) return error.PageLimitExceeded;
        if (self.page_count >= self.limits.max_page_index_entries) {
            return error.PageIndexLimitExceeded;
        }
        if (header.page_number > self.header_value.commit) return error.InvalidPageNumber;
        if (header.page_number == try format.lock_page_number(self.header_value.page_size)) {
            return error.LockPagePresent;
        }
        if (self.header_value.is_snapshot()) {
            try self.validate_snapshot_page_number(header.page_number);
        } else if (header.page_number <= self.previous_page_number) {
            return error.PageOutOfOrder;
        }
    }

    fn validate_snapshot_page_number(self: *Decoder, page_number: u32) format.Error!void {
        if (self.previous_page_number == 0) {
            if (page_number != 1) return error.SnapshotPageSequence;
            return;
        }
        const lock_page = try format.lock_page_number(self.header_value.page_size);
        const increment: u32 = if (self.previous_page_number == lock_page - 1) 2 else 1;
        const expected = std.math.add(u32, self.previous_page_number, increment) catch {
            return error.SnapshotPageSequence;
        };
        if (page_number != expected) return error.SnapshotPageSequence;
    }

    fn decode_flagged_page(
        self: *Decoder,
        page_header: format.PageHeader,
        frame_offset_bytes: u64,
    ) format.Error!DecoderEvent {
        var size_bytes: [format.page_size_prefix_size]u8 = undefined;
        try self.read_exact(&size_bytes);
        self.file_hasher.update(&size_bytes);
        const compressed_size = wire.read_u32_be(&size_bytes);
        if (compressed_size == 0) return error.InvalidCompressedSize;
        if (compressed_size > self.limits.max_compressed_page_size) {
            return error.CompressedPageLimitExceeded;
        }

        const compressed_length = std.math.cast(usize, compressed_size) orelse {
            return error.CompressedPageLimitExceeded;
        };
        const compressed = self.compressed_workspace[0..compressed_length];
        try self.read_exact(compressed);
        const page_length: usize = @intCast(self.header_value.page_size);
        const page = self.page_workspace[0..page_length];
        try lz4_block.decode(compressed, page);
        return self.finish_page(page_header, frame_offset_bytes, page);
    }

    fn decode_legacy_page(
        self: *Decoder,
        page_header: format.PageHeader,
        frame_offset_bytes: u64,
    ) format.Error!DecoderEvent {
        const page_length: usize = @intCast(self.header_value.page_size);
        const page = self.page_workspace[0..page_length];
        const source = lz4_frame.Source{
            .context = self,
            .read_exact_fn = read_legacy_exact,
        };
        const encoded_size = try lz4_frame.decode(
            source,
            self.compressed_workspace,
            page,
            self.limits.max_compressed_page_size,
        );
        const physical_size = self.input_offset_bytes - frame_offset_bytes;
        const header_size_bytes = self.format_version.page_header_size_bytes() catch unreachable;
        std.debug.assert(physical_size == header_size_bytes + encoded_size);
        return self.finish_page(page_header, frame_offset_bytes, page);
    }

    fn finish_page(
        self: *Decoder,
        page_header: format.PageHeader,
        frame_offset_bytes: u64,
        page: []const u8,
    ) format.Error!DecoderEvent {
        self.file_hasher.update(page);
        const frame_size_bytes = self.input_offset_bytes - frame_offset_bytes;
        self.record_page(page_header.page_number, frame_offset_bytes, frame_size_bytes);
        try self.update_snapshot_checksum(page_header.page_number, page);
        return .{ .unverified_page = .{ .header = page_header, .data = page } };
    }

    fn record_page(
        self: *Decoder,
        page_number: u32,
        frame_offset_bytes: u64,
        frame_size_bytes: u64,
    ) void {
        std.debug.assert(self.page_count < self.index_workspace.len);
        self.index_workspace[self.page_count] = .{
            .page_number = page_number,
            .frame_offset_bytes = frame_offset_bytes,
            .frame_size_bytes = frame_size_bytes,
        };
        self.page_count += 1;
        self.previous_page_number = page_number;
    }

    fn update_snapshot_checksum(
        self: *Decoder,
        page_number: u32,
        page: []const u8,
    ) format.Error!void {
        if (!self.header_value.is_snapshot() or self.header_value.no_checksum()) return;
        const lock_page = format.lock_page_number(self.header_value.page_size) catch unreachable;
        std.debug.assert(page_number != lock_page);
        self.snapshot_checksum = try checksum.rolling_add(
            self.snapshot_checksum,
            try checksum.checksum_page(page_number, page),
        );
    }

    fn validate_snapshot_complete(self: *Decoder) format.Error!void {
        if (!self.header_value.is_snapshot()) return;
        const commit = self.header_value.commit;
        const lock_page = try format.lock_page_number(self.header_value.page_size);
        const omitted: u32 = @intFromBool(lock_page <= commit);
        const expected_count = commit - omitted;
        if (self.page_count != expected_count) return error.SnapshotPageSequence;
        if (commit == 0) return;
        const expected_last = if (commit == lock_page) commit - 1 else commit;
        if (self.previous_page_number != expected_last) return error.SnapshotPageSequence;
    }

    fn decode_terminal_event(self: *Decoder) format.Error!DecoderEvent {
        try self.decode_and_verify_index();
        self.state = .trailer;
        const trailer = try self.decode_and_verify_trailer();
        try self.reject_trailing_bytes();
        const verified = self.make_verified(trailer);
        self.state = .verified;
        return .{ .verified = verified };
    }

    fn decode_and_verify_index(self: *Decoder) format.Error!void {
        var entry_index: u32 = 0;
        while (entry_index < self.page_count) : (entry_index += 1) {
            const page_number = try self.read_index_varint();
            if (page_number == 0 or page_number > std.math.maxInt(u32)) {
                return error.InvalidPageIndex;
            }
            const frame_offset_bytes = try self.read_index_varint();
            const frame_size_bytes = try self.read_index_varint();
            const expected = self.index_workspace[entry_index];
            if (page_number != expected.page_number or
                frame_offset_bytes != expected.frame_offset_bytes or
                frame_size_bytes != expected.frame_size_bytes)
            {
                return error.PageIndexMismatch;
            }
        }
        if (try self.read_index_varint() != 0) return error.InvalidPageIndex;
        const encoded_index_bytes = self.input_offset_bytes - self.page_index_offset_bytes;
        var size_bytes: [8]u8 = undefined;
        try self.read_index_bytes(&size_bytes);
        if (wire.read_u64_be(&size_bytes) != encoded_index_bytes) {
            return error.InvalidPageIndexSize;
        }
    }

    fn read_index_varint(self: *Decoder) format.Error!u64 {
        var value: u64 = 0;
        var byte_index: u8 = 0;
        while (byte_index < self.limits.max_varint_bytes) : (byte_index += 1) {
            var byte_buffer: [1]u8 = undefined;
            try self.read_index_bytes(&byte_buffer);
            const byte = byte_buffer[0];
            if (byte_index == 9 and byte > 1) return error.VarintOverflow;
            const shift: u6 = @intCast(byte_index * 7);
            value |= @as(u64, byte & 0x7f) << shift;
            if (byte & 0x80 == 0) {
                if (page_index.encoded_length(value) != byte_index + 1) {
                    return error.OverlongVarint;
                }
                return value;
            }
        }
        if (self.limits.max_varint_bytes < page_index.varint_size_max) {
            return error.PageIndexLimitExceeded;
        }
        return error.VarintOverflow;
    }

    fn read_index_bytes(self: *Decoder, destination: []u8) format.Error!void {
        const length: u64 = @intCast(destination.len);
        const index_bytes = self.input_offset_bytes - self.page_index_offset_bytes;
        const next_index_bytes = std.math.add(u64, index_bytes, length) catch {
            return error.PageIndexLimitExceeded;
        };
        if (next_index_bytes > self.limits.max_page_index_bytes) {
            return error.PageIndexLimitExceeded;
        }
        try self.read_exact(destination);
        self.file_hasher.update(destination);
    }

    fn decode_and_verify_trailer(self: *Decoder) format.Error!format.Trailer {
        var bytes: [format.trailer_size]u8 = undefined;
        try self.read_exact(&bytes);
        self.file_hasher.update(bytes[0..format.trailer_checksum_offset]);
        const trailer = format.decode_trailer(&bytes);
        try trailer.validate(self.header_value);
        if (self.file_hasher.checksum().value != trailer.file_checksum.value) {
            return error.ChecksumMismatch;
        }
        if (self.header_value.is_snapshot() and !self.header_value.no_checksum() and
            self.snapshot_checksum.value != trailer.post_apply_checksum.value)
        {
            return error.SnapshotChecksumMismatch;
        }
        return trailer;
    }

    fn reject_trailing_bytes(self: *Decoder) format.Error!void {
        if (!try self.reader.at_end()) return error.TrailingBytes;
    }

    fn make_verified(self: *const Decoder, trailer: format.Trailer) format.VerifiedLTX {
        std.debug.assert(self.state == .trailer);
        return .{
            .format_version = self.format_version,
            .header = self.header_value,
            .trailer = trailer,
            .page_count = self.page_count,
            .byte_count = self.input_offset_bytes,
        };
    }

    fn read_exact(self: *Decoder, destination: []u8) format.Error!void {
        const length: u64 = @intCast(destination.len);
        const final_offset = std.math.add(u64, self.input_offset_bytes, length) catch {
            return error.InputLimitExceeded;
        };
        if (final_offset > self.limits.max_input_bytes) return error.InputLimitExceeded;
        var completed: usize = 0;
        while (completed < destination.len) {
            const count = try self.reader.read(destination[completed..]);
            if (count == 0) return error.TruncatedInput;
            completed += count;
            self.input_offset_bytes += @intCast(count);
        }
        std.debug.assert(self.input_offset_bytes == final_offset);
    }

    fn read_legacy_exact(context: *anyopaque, destination: []u8) format.Error!void {
        const self: *Decoder = @ptrCast(@alignCast(context));
        try self.read_exact(destination);
    }
};
