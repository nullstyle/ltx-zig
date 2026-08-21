const std = @import("std");
const checksum = @import("checksum.zig");
const format = @import("format.zig");
const lz4_block = @import("lz4_block.zig");
const page_index = @import("page_index.zig");
const Limits = @import("limits.zig").Limits;
const Writer = @import("transport.zig").Writer;
const wire = @import("wire.zig");
const workspace = @import("workspace.zig");

pub const EncoderState = enum {
    initialized,
    pages,
    index_written,
    trailer_written,
    finished,
    failed,
};

pub const Encoder = struct {
    writer: Writer,
    format_version: format.FormatVersion,
    limits: Limits,
    compressed_workspace: []u8,
    index_workspace: []format.PageIndexEntry,
    state: EncoderState = .initialized,
    header_value: format.Header = undefined,
    file_hasher: checksum.FileHasher = .{},
    snapshot_checksum: format.Checksum = .init(0),
    output_offset_bytes: u64 = 0,
    page_count: u32 = 0,
    previous_page_number: u32 = 0,
    page_index_offset_bytes: u64 = 0,

    pub fn init(
        version: format.FormatVersion,
        limits: Limits,
        writer: Writer,
        compressed_workspace: []u8,
        index_workspace: []format.PageIndexEntry,
    ) format.Error!Encoder {
        try version.validate();
        limits.validate() catch return error.InvalidLimits;
        if (limits.max_compressed_page_size < lz4_block.literal_bound(limits.max_page_size)) {
            return error.InvalidLimits;
        }
        const compressed_required = std.math.cast(usize, limits.max_compressed_page_size) orelse {
            return error.InvalidLimits;
        };
        const index_required = std.math.cast(usize, limits.max_page_index_entries) orelse {
            return error.InvalidLimits;
        };
        if (compressed_workspace.len < compressed_required) return error.WorkspaceTooSmall;
        if (index_workspace.len < index_required) return error.WorkspaceTooSmall;
        if (workspace.slices_overlap(
            compressed_workspace,
            std.mem.sliceAsBytes(index_workspace),
        )) return error.WorkspaceAliasing;
        if (writer.backing_bytes) |backing| {
            if (workspace.slices_overlap(backing, compressed_workspace) or
                workspace.slices_overlap(backing, std.mem.sliceAsBytes(index_workspace)))
            {
                return error.WorkspaceAliasing;
            }
        }
        return .{
            .writer = writer,
            .format_version = version,
            .limits = limits,
            .compressed_workspace = compressed_workspace,
            .index_workspace = index_workspace,
        };
    }

    pub fn write_header(self: *Encoder, header: format.Header) format.Error!void {
        if (self.state != .initialized) return error.InvalidState;
        self.write_header_internal(header) catch |err| {
            self.state = .failed;
            return err;
        };
    }

    pub fn write_page(
        self: *Encoder,
        page_number: u32,
        page: []const u8,
    ) format.Error!void {
        if (self.state != .pages) return error.InvalidState;
        self.write_page_internal(page_number, page) catch |err| {
            self.state = .failed;
            return err;
        };
    }

    pub fn finish(
        self: *Encoder,
        post_apply_checksum: format.Checksum,
    ) format.Error!format.VerifiedLTX {
        if (self.state != .pages) return error.InvalidState;
        const verified = self.finish_internal(post_apply_checksum) catch |err| {
            self.state = .failed;
            return err;
        };
        self.state = .finished;
        return verified;
    }

    pub fn current_state(self: *const Encoder) EncoderState {
        return self.state;
    }

    pub fn selected_format_version(self: *const Encoder) format.FormatVersion {
        return self.format_version;
    }

    fn write_header_internal(self: *Encoder, header: format.Header) format.Error!void {
        try header.validate(self.limits);
        var bytes: [format.header_size]u8 = undefined;
        format.encode_header(header, &bytes);
        try self.write_structural(&bytes);
        self.header_value = header;
        if (header.is_snapshot() and !header.no_checksum()) {
            self.snapshot_checksum = checksum.rolling_initial();
        }
        self.state = .pages;
    }

    fn write_page_internal(
        self: *Encoder,
        page_number: u32,
        page: []const u8,
    ) format.Error!void {
        const page_length: usize = @intCast(self.header_value.page_size);
        if (page.len != page_length) return error.InvalidPageDataSize;
        if (workspace.slices_overlap(page, self.compressed_workspace) or
            workspace.slices_overlap(page, std.mem.sliceAsBytes(self.index_workspace)))
        {
            return error.WorkspaceAliasing;
        }
        if (self.writer.backing_bytes) |backing| {
            if (workspace.slices_overlap(page, backing)) return error.WorkspaceAliasing;
        }
        try self.validate_page_number(page_number);

        const compressed = try lz4_block.encode_literal(page, self.compressed_workspace);
        if (compressed.len > self.limits.max_compressed_page_size) {
            return error.CompressedPageLimitExceeded;
        }
        const frame_size_bytes = @as(u64, format.page_header_size) +
            @as(u64, format.page_size_prefix_size) +
            @as(u64, @intCast(compressed.len));
        try self.ensure_output_capacity(frame_size_bytes);
        const frame_offset_bytes = self.output_offset_bytes;
        try self.write_page_frame(page_number, page, compressed);
        std.debug.assert(self.output_offset_bytes - frame_offset_bytes == frame_size_bytes);
        self.record_page(page_number, frame_offset_bytes, frame_size_bytes);
        try self.update_snapshot_checksum(page_number, page);
    }

    fn validate_page_number(self: *const Encoder, page_number: u32) format.Error!void {
        if (page_number == 0 or page_number > self.header_value.commit) {
            return error.InvalidPageNumber;
        }
        if (self.page_count >= self.limits.max_pages) return error.PageLimitExceeded;
        if (self.page_count >= self.limits.max_page_index_entries) {
            return error.PageIndexLimitExceeded;
        }
        const lock_page = try format.lock_page_number(self.header_value.page_size);
        if (page_number == lock_page) return error.LockPagePresent;
        if (!self.header_value.is_snapshot()) {
            if (page_number <= self.previous_page_number) return error.PageOutOfOrder;
            return;
        }
        if (self.previous_page_number == 0) {
            if (page_number != 1) return error.SnapshotPageSequence;
            return;
        }
        const increment: u32 = if (self.previous_page_number == lock_page - 1) 2 else 1;
        const expected = std.math.add(u32, self.previous_page_number, increment) catch {
            return error.SnapshotPageSequence;
        };
        if (page_number != expected) return error.SnapshotPageSequence;
    }

    fn write_page_frame(
        self: *Encoder,
        page_number: u32,
        page: []const u8,
        compressed: []const u8,
    ) format.Error!void {
        var header_bytes: [format.page_header_size]u8 = undefined;
        format.encode_page_header(.{
            .page_number = page_number,
            .flags = format.page_header_flag_size,
        }, &header_bytes);
        try self.write_structural(&header_bytes);

        var size_bytes: [format.page_size_prefix_size]u8 = undefined;
        wire.write_u32_be(&size_bytes, @intCast(compressed.len));
        try self.write_structural(&size_bytes);
        try self.write_bytes(compressed);
        self.file_hasher.update(page);
    }

    fn record_page(
        self: *Encoder,
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
        self: *Encoder,
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

    fn finish_internal(
        self: *Encoder,
        post_apply_checksum: format.Checksum,
    ) format.Error!format.VerifiedLTX {
        try self.validate_snapshot_complete();
        try self.validate_post_apply_checksum(post_apply_checksum);
        const index_size_bytes = try self.page_index_size_bytes();
        const terminal_size_bytes = @as(u64, format.page_header_size) +
            index_size_bytes +
            @as(u64, format.trailer_size);
        try self.ensure_output_capacity(terminal_size_bytes);
        var terminator: [format.page_header_size]u8 = @splat(0);
        try self.write_structural(&terminator);
        try self.write_page_index();
        self.state = .index_written;

        var post_checksum_bytes: [8]u8 = undefined;
        wire.write_u64_be(&post_checksum_bytes, post_apply_checksum.value);
        try self.write_structural(&post_checksum_bytes);
        const trailer = format.Trailer{
            .post_apply_checksum = post_apply_checksum,
            .file_checksum = self.file_hasher.checksum(),
        };
        try trailer.validate(self.header_value);
        var file_checksum_bytes: [8]u8 = undefined;
        wire.write_u64_be(&file_checksum_bytes, trailer.file_checksum.value);
        try self.write_bytes(&file_checksum_bytes);
        self.state = .trailer_written;
        return self.make_verified(trailer);
    }

    fn validate_snapshot_complete(self: *const Encoder) format.Error!void {
        if (!self.header_value.is_snapshot()) return;
        const commit = self.header_value.commit;
        const lock_page = try format.lock_page_number(self.header_value.page_size);
        const expected_count = commit - @as(u32, @intFromBool(lock_page <= commit));
        if (self.page_count != expected_count) return error.SnapshotPageSequence;
        if (commit == 0) return;
        const expected_last = if (commit == lock_page) commit - 1 else commit;
        if (self.previous_page_number != expected_last) return error.SnapshotPageSequence;
    }

    fn validate_post_apply_checksum(
        self: *const Encoder,
        post_apply_checksum: format.Checksum,
    ) format.Error!void {
        if (self.header_value.no_checksum()) {
            if (post_apply_checksum.value != 0) return error.InvalidTrailer;
            return;
        }
        if (!post_apply_checksum.has_valid_flag()) return error.InvalidTrailer;
        if (self.header_value.commit == 0 and
            post_apply_checksum.value != format.checksum_flag)
        {
            return error.InvalidTrailer;
        }
        if (self.header_value.is_snapshot() and
            post_apply_checksum.value != self.snapshot_checksum.value)
        {
            return error.SnapshotChecksumMismatch;
        }
    }

    fn write_page_index(self: *Encoder) format.Error!void {
        self.page_index_offset_bytes = self.output_offset_bytes;
        var entry_index: u32 = 0;
        while (entry_index < self.page_count) : (entry_index += 1) {
            const entry = self.index_workspace[entry_index];
            try self.write_index_varint(entry.page_number);
            try self.write_index_varint(entry.frame_offset_bytes);
            try self.write_index_varint(entry.frame_size_bytes);
        }
        try self.write_index_varint(0);
        const encoded_index_bytes = self.output_offset_bytes - self.page_index_offset_bytes;
        var size_bytes: [8]u8 = undefined;
        wire.write_u64_be(&size_bytes, encoded_index_bytes);
        try self.write_index_bytes(&size_bytes);
    }

    fn page_index_size_bytes(self: *const Encoder) format.Error!u64 {
        var size: u64 = 0;
        var entry_index: u32 = 0;
        while (entry_index < self.page_count) : (entry_index += 1) {
            const entry = self.index_workspace[entry_index];
            const values = [_]u64{
                entry.page_number,
                entry.frame_offset_bytes,
                entry.frame_size_bytes,
            };
            for (values) |value| {
                const encoded_size = page_index.encoded_length(value);
                if (encoded_size > self.limits.max_varint_bytes) {
                    return error.PageIndexLimitExceeded;
                }
                size = std.math.add(u64, size, encoded_size) catch {
                    return error.PageIndexLimitExceeded;
                };
            }
        }
        if (page_index.encoded_length(0) > self.limits.max_varint_bytes) {
            return error.PageIndexLimitExceeded;
        }
        size = std.math.add(u64, size, page_index.encoded_length(0)) catch {
            return error.PageIndexLimitExceeded;
        };
        size = std.math.add(u64, size, @sizeOf(u64)) catch {
            return error.PageIndexLimitExceeded;
        };
        if (size > self.limits.max_page_index_bytes) {
            return error.PageIndexLimitExceeded;
        }
        return size;
    }

    fn write_index_varint(self: *Encoder, value: u64) format.Error!void {
        const encoded_size = page_index.encoded_length(value);
        if (encoded_size > self.limits.max_varint_bytes) {
            return error.PageIndexLimitExceeded;
        }
        var buffer: [page_index.varint_size_max]u8 = undefined;
        try self.write_index_bytes(page_index.encode(value, &buffer));
    }

    fn write_index_bytes(self: *Encoder, bytes: []const u8) format.Error!void {
        const current = self.output_offset_bytes - self.page_index_offset_bytes;
        const next = std.math.add(u64, current, @intCast(bytes.len)) catch {
            return error.PageIndexLimitExceeded;
        };
        if (next > self.limits.max_page_index_bytes) {
            return error.PageIndexLimitExceeded;
        }
        try self.write_structural(bytes);
    }

    fn make_verified(self: *const Encoder, trailer: format.Trailer) format.VerifiedLTX {
        std.debug.assert(self.state == .trailer_written);
        return .{
            .format_version = self.format_version,
            .header = self.header_value,
            .trailer = trailer,
            .page_count = self.page_count,
            .byte_count = self.output_offset_bytes,
        };
    }

    fn write_structural(self: *Encoder, bytes: []const u8) format.Error!void {
        try self.write_bytes(bytes);
        self.file_hasher.update(bytes);
    }

    fn write_bytes(self: *Encoder, bytes: []const u8) format.Error!void {
        try self.ensure_output_capacity(@intCast(bytes.len));
        try self.writer.write_all(bytes);
        self.output_offset_bytes += @intCast(bytes.len);
    }

    fn ensure_output_capacity(self: *const Encoder, additional_bytes: u64) format.Error!void {
        const final_offset = std.math.add(u64, self.output_offset_bytes, additional_bytes) catch {
            return error.OutputLimitExceeded;
        };
        if (final_offset > self.limits.max_output_bytes) return error.OutputLimitExceeded;
    }
};
