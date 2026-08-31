const std = @import("std");
const Decoder = @import("decoder.zig").Decoder;
const Encoder = @import("encoder.zig").Encoder;
const format = @import("format.zig");
const Limits = @import("limits.zig").Limits;
const lz4_block = @import("lz4_block.zig");
const Reader = @import("transport.zig").Reader;
const Writer = @import("transport.zig").Writer;
const workspace = @import("workspace.zig");

pub const CompactionLimits = struct {
    /// Maximum number of chronologically ordered input streams.
    max_inputs: u32,
    /// Sum of pages decoded from every input, including overwritten or dropped
    /// pages rather than only pages emitted in the compacted output.
    max_total_pages: u64,

    pub fn validate(self: CompactionLimits) error{InvalidLimits}!void {
        if (self.max_inputs == 0 or self.max_total_pages == 0) {
            return error.InvalidLimits;
        }
    }
};

pub const CompactorState = enum {
    initialized,
    compacting,
    finished,
    failed,
};

/// One chronologically ordered compaction source and all variable-size decoder
/// storage it may use. The value must remain at a stable address in the input
/// slice supplied to `Compactor.init` until compaction reaches a terminal state.
pub const CompactionInput = struct {
    format_version: format.FormatVersion,
    reader: Reader,
    page_workspace: []u8,
    compressed_workspace: []u8,
    index_workspace: []format.PageIndexEntry,
    decoder: Decoder = undefined,
    header_value: ?format.Header = null,
    verified_value: ?format.VerifiedLTX = null,
    page_number: ?u32 = null,

    pub fn init(
        version: format.FormatVersion,
        reader: Reader,
        page_workspace: []u8,
        compressed_workspace: []u8,
        index_workspace: []format.PageIndexEntry,
    ) CompactionInput {
        return .{
            .format_version = version,
            .reader = reader,
            .page_workspace = page_workspace,
            .compressed_workspace = compressed_workspace,
            .index_workspace = index_workspace,
        };
    }

    fn initialize_decoder(
        self: *CompactionInput,
        limits: Limits,
    ) format.Error!void {
        self.decoder = try Decoder.init(
            self.format_version,
            limits,
            self.reader,
            self.page_workspace,
            self.compressed_workspace,
            self.index_workspace,
        );
        self.header_value = null;
        self.verified_value = null;
        self.page_number = null;
    }
};

/// Allocation-free, one-shot merge of oldest-to-newest LTX inputs. Output may
/// be partially written before a late input fails verification, so only the
/// `VerifiedLTX` returned by `compact` authorizes publication of output bytes.
/// This is a stateful, single-owner value and must not be copied after init.
pub const Compactor = struct {
    format_version: format.FormatVersion,
    compaction_limits: CompactionLimits,
    inputs: []CompactionInput,
    encoder: Encoder,
    state: CompactorState = .initialized,
    total_page_count: u64 = 0,

    pub fn init(
        output_version: format.FormatVersion,
        codec_limits: Limits,
        compaction_limits: CompactionLimits,
        inputs: []CompactionInput,
        writer: Writer,
        output_compressed_workspace: []u8,
        output_compression_workspace: *lz4_block.CompressionWorkspace,
        output_index_workspace: []format.PageIndexEntry,
    ) format.Error!Compactor {
        try output_version.validate_for_encoding();
        codec_limits.validate() catch return error.InvalidLimits;
        try compaction_limits.validate();
        if (inputs.len == 0) return error.CompactionInputRequired;
        if (inputs.len > @as(usize, compaction_limits.max_inputs)) {
            return error.CompactionInputLimitExceeded;
        }
        try validate_input_shapes(codec_limits, inputs);
        const output_ranges = output_workspace_ranges(
            output_compressed_workspace,
            output_compression_workspace,
            output_index_workspace,
        );
        try validate_global_aliasing(inputs, writer, output_ranges);
        const encoder = try Encoder.init(
            output_version,
            codec_limits,
            writer,
            output_compressed_workspace,
            output_compression_workspace,
            output_index_workspace,
        );
        try initialize_inputs(codec_limits, inputs);
        return .{
            .format_version = output_version,
            .compaction_limits = compaction_limits,
            .inputs = inputs,
            .encoder = encoder,
        };
    }

    pub fn compact(self: *Compactor) format.Error!format.VerifiedLTX {
        if (self.state != .initialized) return error.InvalidState;
        self.state = .compacting;
        const verified = self.compact_internal() catch |err| {
            self.state = .failed;
            return err;
        };
        self.state = .finished;
        return verified;
    }

    pub fn current_state(self: *const Compactor) CompactorState {
        return self.state;
    }

    pub fn selected_format_version(self: *const Compactor) format.FormatVersion {
        return self.format_version;
    }

    fn compact_internal(self: *Compactor) format.Error!format.VerifiedLTX {
        try self.read_headers();
        try self.validate_headers();
        try self.encoder.write_header(try self.output_header());
        try self.prime_inputs();
        try self.merge_pages();
        try self.verify_chain();
        const final = self.inputs[self.inputs.len - 1].verified_value orelse
            return error.InvalidState;
        return self.encoder.finish(final.trailer.post_apply_checksum);
    }

    fn read_headers(self: *Compactor) format.Error!void {
        const input_count: u32 = @intCast(self.inputs.len);
        var input_index: u32 = 0;
        while (input_index < input_count) : (input_index += 1) {
            const input = &self.inputs[@intCast(input_index)];
            const event = try input.decoder.next();
            switch (event) {
                .header => |header| input.header_value = header,
                else => return error.InvalidState,
            }
        }
    }

    fn validate_headers(self: *const Compactor) format.Error!void {
        const first = self.inputs[0].header_value orelse return error.InvalidState;
        const input_count: u32 = @intCast(self.inputs.len);
        var input_index: u32 = 1;
        while (input_index < input_count) : (input_index += 1) {
            const previous = self.inputs[@intCast(input_index - 1)].header_value orelse
                return error.InvalidState;
            const current = self.inputs[@intCast(input_index)].header_value orelse
                return error.InvalidState;
            if (current.page_size != first.page_size) {
                return error.CompactionPageSizeMismatch;
            }
            if (current.no_checksum() != first.no_checksum()) {
                return error.CompactionChecksumModeMismatch;
            }
            const expected_min = std.math.add(u64, previous.max_txid.value, 1) catch
                return error.NonContiguousTransition;
            if (current.min_txid.value != expected_min) {
                return error.NonContiguousTransition;
            }
        }
    }

    fn output_header(self: *const Compactor) format.Error!format.Header {
        const first = self.inputs[0].header_value orelse return error.InvalidState;
        const last = self.inputs[self.inputs.len - 1].header_value orelse
            return error.InvalidState;
        return .{
            .flags = if (first.no_checksum()) format.header_flag_no_checksum else 0,
            .page_size = first.page_size,
            .commit = last.commit,
            .min_txid = first.min_txid,
            .max_txid = last.max_txid,
            .timestamp_ms = last.timestamp_ms,
            .pre_apply_checksum = if (first.no_checksum()) .init(0) else first.pre_apply_checksum,
            .wal_offset = 0,
            .wal_size = 0,
            .wal_salt_1 = 0,
            .wal_salt_2 = 0,
            .node_id = 0,
        };
    }

    fn prime_inputs(self: *Compactor) format.Error!void {
        const input_count: u32 = @intCast(self.inputs.len);
        var input_index: u32 = 0;
        while (input_index < input_count) : (input_index += 1) {
            try self.advance_input(input_index);
        }
    }

    fn merge_pages(self: *Compactor) format.Error!void {
        const last_header = self.inputs[self.inputs.len - 1].header_value orelse
            return error.InvalidState;
        var iteration: u64 = 0;
        while (iteration < self.compaction_limits.max_total_pages) : (iteration += 1) {
            const page_number = self.next_page_number() orelse break;
            if (page_number <= last_header.commit) {
                try self.write_newest_page(page_number);
            }
            try self.consume_page_number(page_number);
        }
        if (self.next_page_number() != null) return error.CompactionPageLimitExceeded;
    }

    fn next_page_number(self: *const Compactor) ?u32 {
        const input_count: u32 = @intCast(self.inputs.len);
        var selected: ?u32 = null;
        var input_index: u32 = 0;
        while (input_index < input_count) : (input_index += 1) {
            const candidate = self.inputs[@intCast(input_index)].page_number orelse continue;
            if (selected == null or candidate < selected.?) selected = candidate;
        }
        return selected;
    }

    fn write_newest_page(self: *Compactor, page_number: u32) format.Error!void {
        const input_count: u32 = @intCast(self.inputs.len);
        var selected_index: ?u32 = null;
        var input_index: u32 = 0;
        while (input_index < input_count) : (input_index += 1) {
            if (self.inputs[@intCast(input_index)].page_number == page_number) {
                selected_index = input_index;
            }
        }
        const selected = &self.inputs[@intCast(selected_index orelse return error.InvalidState)];
        const header = selected.header_value orelse return error.InvalidState;
        const page_size: usize = @intCast(header.page_size);
        try self.encoder.write_page(page_number, selected.page_workspace[0..page_size]);
    }

    fn consume_page_number(self: *Compactor, page_number: u32) format.Error!void {
        const input_count: u32 = @intCast(self.inputs.len);
        var input_index: u32 = 0;
        while (input_index < input_count) : (input_index += 1) {
            const input = &self.inputs[@intCast(input_index)];
            if (input.page_number != page_number) continue;
            input.page_number = null;
            try self.advance_input(input_index);
        }
    }

    fn advance_input(self: *Compactor, input_index: u32) format.Error!void {
        const input = &self.inputs[@intCast(input_index)];
        std.debug.assert(input.page_number == null and input.verified_value == null);
        if (self.total_page_count == self.compaction_limits.max_total_pages) {
            return advance_input_at_page_limit(input);
        }
        const event = try input.decoder.next();
        switch (event) {
            .unverified_page => |page| {
                const next_total = std.math.add(u64, self.total_page_count, 1) catch
                    return error.CompactionPageLimitExceeded;
                std.debug.assert(next_total <= self.compaction_limits.max_total_pages);
                self.total_page_count = next_total;
                input.page_number = page.header.page_number;
            },
            .page_block_complete => try finish_input(input),
            else => return error.InvalidState,
        }
    }

    fn verify_chain(self: *const Compactor) format.Error!void {
        var previous = self.inputs[0].verified_value orelse return error.InvalidState;
        const input_count: u32 = @intCast(self.inputs.len);
        var input_index: u32 = 1;
        while (input_index < input_count) : (input_index += 1) {
            const current = self.inputs[@intCast(input_index)].verified_value orelse
                return error.InvalidState;
            try current.check_contiguous(previous.post_apply_position());
            previous = current;
        }
    }
};

/// Allows an exact-limit input to consume its page terminator without allowing
/// the decoder to read or emit another page payload.
const TerminalProbe = struct {
    upstream: Reader,
    remaining_bytes: usize,
    blocked: bool = false,

    fn reader(self: *TerminalProbe) Reader {
        return .{
            .context = self,
            .read_fn = read,
            .at_end_fn = at_end,
            .backing_bytes = self.upstream.backing_bytes,
            .backing_is_mutable = self.upstream.backing_is_mutable,
        };
    }

    fn read(context: *anyopaque, destination: []u8) error{InputFailure}!usize {
        const self: *TerminalProbe = @ptrCast(@alignCast(context));
        if (self.remaining_bytes == 0) {
            self.blocked = true;
            return error.InputFailure;
        }
        const allowed = @min(destination.len, self.remaining_bytes);
        const count = try self.upstream.read(destination[0..allowed]);
        self.remaining_bytes -= count;
        return count;
    }

    fn at_end(context: *anyopaque) error{InputFailure}!bool {
        const self: *TerminalProbe = @ptrCast(@alignCast(context));
        return self.upstream.at_end();
    }
};

fn advance_input_at_page_limit(input: *CompactionInput) format.Error!void {
    var probe = TerminalProbe{
        .upstream = input.reader,
        .remaining_bytes = @intCast(
            input.decoder.selected_format_version().page_header_size_bytes() catch unreachable,
        ),
    };
    input.decoder.reader = probe.reader();
    const event = input.decoder.next() catch |err| {
        input.decoder.reader = input.reader;
        if (probe.blocked) return error.CompactionPageLimitExceeded;
        return err;
    };
    input.decoder.reader = input.reader;
    switch (event) {
        .page_block_complete => try finish_input(input),
        .unverified_page => return error.CompactionPageLimitExceeded,
        else => return error.InvalidState,
    }
}

const WorkspaceRanges = [3][]const u8;

fn initialize_inputs(
    limits: Limits,
    inputs: []CompactionInput,
) format.Error!void {
    const input_count: u32 = @intCast(inputs.len);
    var input_index: u32 = 0;
    while (input_index < input_count) : (input_index += 1) {
        try inputs[@intCast(input_index)].initialize_decoder(limits);
    }
}

fn finish_input(input: *CompactionInput) format.Error!void {
    const terminal = try input.decoder.next();
    switch (terminal) {
        .verified => |verified| input.verified_value = verified,
        else => return error.InvalidState,
    }
}

fn validate_input_shapes(limits: Limits, inputs: []const CompactionInput) format.Error!void {
    const page_required = std.math.cast(usize, limits.max_page_size) orelse
        return error.InvalidLimits;
    const compressed_required = std.math.cast(usize, limits.max_compressed_page_size) orelse
        return error.InvalidLimits;
    const index_required = std.math.cast(usize, limits.max_page_index_entries) orelse
        return error.InvalidLimits;
    const input_count: u32 = @intCast(inputs.len);
    var input_index: u32 = 0;
    while (input_index < input_count) : (input_index += 1) {
        const input = &inputs[@intCast(input_index)];
        if (input.page_workspace.len < page_required or
            input.compressed_workspace.len < compressed_required or
            input.index_workspace.len < index_required)
        {
            return error.WorkspaceTooSmall;
        }
        const ranges = input_workspace_ranges(input);
        if (has_internal_overlap(ranges)) return error.WorkspaceAliasing;
        if (input.reader.backing_bytes) |backing| {
            if (overlaps_any(backing, ranges)) return error.WorkspaceAliasing;
        }
    }
}

fn validate_global_aliasing(
    inputs: []CompactionInput,
    writer: Writer,
    output_ranges: WorkspaceRanges,
) format.Error!void {
    const input_state = std.mem.sliceAsBytes(inputs);
    if (overlaps_any(input_state, output_ranges)) return error.WorkspaceAliasing;
    if (writer.backing_bytes) |backing| {
        if (workspace.slices_overlap(input_state, backing) or
            overlaps_any(backing, output_ranges)) return error.WorkspaceAliasing;
    }
    const input_count: u32 = @intCast(inputs.len);
    var input_index: u32 = 0;
    while (input_index < input_count) : (input_index += 1) {
        try validate_input_cross_aliases(
            inputs,
            input_index,
            input_state,
            writer.backing_bytes,
            output_ranges,
        );
    }
}

fn validate_input_cross_aliases(
    inputs: []const CompactionInput,
    input_index: u32,
    input_state: []const u8,
    writer_backing: ?[]const u8,
    output_ranges: WorkspaceRanges,
) format.Error!void {
    const input = &inputs[@intCast(input_index)];
    const ranges = input_workspace_ranges(input);
    if (overlaps_any(input_state, ranges) or ranges_overlap(ranges, output_ranges)) {
        return error.WorkspaceAliasing;
    }
    if (writer_backing) |backing| {
        if (overlaps_any(backing, ranges)) return error.WorkspaceAliasing;
    }
    if (input.reader.backing_bytes) |backing| {
        if (workspace.slices_overlap(backing, input_state) or
            overlaps_any(backing, output_ranges)) return error.WorkspaceAliasing;
        if (writer_backing) |output| {
            if (workspace.slices_overlap(backing, output)) return error.WorkspaceAliasing;
        }
    }
    try validate_later_input_aliases(inputs, input_index, ranges);
}

fn validate_later_input_aliases(
    inputs: []const CompactionInput,
    input_index: u32,
    ranges: WorkspaceRanges,
) format.Error!void {
    const input_count: u32 = @intCast(inputs.len);
    var later_index = input_index + 1;
    while (later_index < input_count) : (later_index += 1) {
        const later = &inputs[@intCast(later_index)];
        const later_ranges = input_workspace_ranges(later);
        if (ranges_overlap(ranges, later_ranges)) return error.WorkspaceAliasing;
        if (inputs[@intCast(input_index)].reader.backing_bytes) |backing| {
            if (overlaps_any(backing, later_ranges)) return error.WorkspaceAliasing;
        }
        if (later.reader.backing_bytes) |backing| {
            if (overlaps_any(backing, ranges)) return error.WorkspaceAliasing;
        }
        if (readers_share_mutable_backing(
            inputs[@intCast(input_index)].reader,
            later.reader,
        )) return error.WorkspaceAliasing;
    }
}

fn readers_share_mutable_backing(left: Reader, right: Reader) bool {
    if (!left.backing_is_mutable and !right.backing_is_mutable) return false;
    const left_backing = left.backing_bytes orelse return false;
    const right_backing = right.backing_bytes orelse return false;
    return workspace.slices_overlap(left_backing, right_backing);
}

fn input_workspace_ranges(input: *const CompactionInput) WorkspaceRanges {
    return .{
        input.page_workspace,
        input.compressed_workspace,
        std.mem.sliceAsBytes(input.index_workspace),
    };
}

fn output_workspace_ranges(
    compressed: []u8,
    compression: *lz4_block.CompressionWorkspace,
    index: []format.PageIndexEntry,
) WorkspaceRanges {
    return .{
        compressed,
        std.mem.asBytes(compression),
        std.mem.sliceAsBytes(index),
    };
}

fn has_internal_overlap(ranges: WorkspaceRanges) bool {
    var left_index: u8 = 0;
    while (left_index < ranges.len) : (left_index += 1) {
        var right_index = left_index + 1;
        while (right_index < ranges.len) : (right_index += 1) {
            if (workspace.slices_overlap(
                ranges[left_index],
                ranges[right_index],
            )) return true;
        }
    }
    return false;
}

fn overlaps_any(range: []const u8, ranges: WorkspaceRanges) bool {
    for (ranges) |candidate| {
        if (workspace.slices_overlap(range, candidate)) return true;
    }
    return false;
}

fn ranges_overlap(left: WorkspaceRanges, right: WorkspaceRanges) bool {
    for (left) |left_range| {
        if (overlaps_any(left_range, right)) return true;
    }
    return false;
}

test "compactor merges a verified snapshot chain with newest pages winning" {
    const transport = @import("transport.zig");
    const limits = Limits{
        .max_input_bytes = 4096,
        .max_output_bytes = 4096,
        .max_pages = 4,
        .max_page_size = 512,
        .max_compressed_page_size = 600,
        .max_page_index_bytes = 256,
        .max_page_index_entries = 4,
        .max_varint_bytes = 10,
        .max_transaction_span = 4,
    };
    const page_a: [512]u8 = @splat(0xa1);
    const page_b: [512]u8 = @splat(0xb2);
    const page_c: [512]u8 = @splat(0xc3);
    const snapshot_checksum = try test_database_checksum(&.{ page_a, page_b });
    const final_checksum = try test_database_checksum(&.{ page_a, page_c });

    var first_bytes: [4096]u8 = undefined;
    var first_sink = transport.SliceWriter.init(&first_bytes);
    try encode_test_input(
        limits,
        first_sink.writer(),
        test_header(1, 1, .init(0)),
        &.{ page_a, page_b },
        snapshot_checksum,
    );
    var second_bytes: [4096]u8 = undefined;
    var second_sink = transport.SliceWriter.init(&second_bytes);
    try encode_test_input(
        limits,
        second_sink.writer(),
        test_header(2, 2, snapshot_checksum),
        &.{page_c},
        final_checksum,
    );

    var first_source = transport.SliceReader.init(first_sink.written());
    var second_source = transport.SliceReader.init(second_sink.written());
    var input_pages: [2][512]u8 = undefined;
    var input_compressed: [2][600]u8 = undefined;
    var input_indexes: [2][4]format.PageIndexEntry = undefined;
    var inputs = [_]CompactionInput{
        CompactionInput.init(.v3, first_source.reader(), &input_pages[0], &input_compressed[0], &input_indexes[0]),
        CompactionInput.init(.v3, second_source.reader(), &input_pages[1], &input_compressed[1], &input_indexes[1]),
    };
    var output_bytes: [4096]u8 = undefined;
    var output_sink = transport.SliceWriter.init(&output_bytes);
    var output_compressed: [600]u8 = undefined;
    var output_compression: lz4_block.CompressionWorkspace = undefined;
    var output_index: [4]format.PageIndexEntry = undefined;
    var compactor = try Compactor.init(
        .v3,
        limits,
        .{ .max_inputs = 2, .max_total_pages = 3 },
        &inputs,
        output_sink.writer(),
        &output_compressed,
        &output_compression,
        &output_index,
    );
    const compacted = try compactor.compact();
    try std.testing.expectEqual(CompactorState.finished, compactor.current_state());
    try std.testing.expectEqual(@as(u64, 3), compactor.total_page_count);
    try std.testing.expectEqual(@as(u32, 2), compacted.page_count);
    try std.testing.expectEqual(final_checksum, compacted.trailer.post_apply_checksum);
    try verify_test_output(limits, output_sink.written(), page_a, page_c);
}

test "compactor validates the aggregate output transaction span" {
    const transport = @import("transport.zig");
    const limits = Limits{
        .max_input_bytes = 4096,
        .max_output_bytes = 4096,
        .max_pages = 2,
        .max_page_size = 512,
        .max_compressed_page_size = 600,
        .max_page_index_bytes = 128,
        .max_page_index_entries = 2,
        .max_varint_bytes = 10,
        .max_transaction_span = 1,
    };
    const page_a: [512]u8 = @splat(0xa1);
    const page_b: [512]u8 = @splat(0xb2);
    const page_c: [512]u8 = @splat(0xc3);
    const snapshot_checksum = try test_database_checksum(&.{ page_a, page_b });
    const final_checksum = try test_database_checksum(&.{ page_a, page_c });

    var first_bytes: [4096]u8 = undefined;
    var first_sink = transport.SliceWriter.init(&first_bytes);
    try encode_test_input(
        limits,
        first_sink.writer(),
        test_header(1, 1, .init(0)),
        &.{ page_a, page_b },
        snapshot_checksum,
    );
    var second_bytes: [4096]u8 = undefined;
    var second_sink = transport.SliceWriter.init(&second_bytes);
    try encode_test_input(
        limits,
        second_sink.writer(),
        test_header(2, 2, snapshot_checksum),
        &.{page_c},
        final_checksum,
    );
    var first_source = transport.SliceReader.init(first_sink.written());
    var second_source = transport.SliceReader.init(second_sink.written());
    var pages: [2][512]u8 = undefined;
    var compressed: [2][600]u8 = undefined;
    var indexes: [2][2]format.PageIndexEntry = undefined;
    var inputs = [_]CompactionInput{
        CompactionInput.init(.v3, first_source.reader(), &pages[0], &compressed[0], &indexes[0]),
        CompactionInput.init(.v3, second_source.reader(), &pages[1], &compressed[1], &indexes[1]),
    };
    var output: [4096]u8 = undefined;
    var sink = transport.SliceWriter.init(&output);
    var output_compressed: [600]u8 = undefined;
    var output_compression: lz4_block.CompressionWorkspace = undefined;
    var output_index: [2]format.PageIndexEntry = undefined;
    var compactor = try Compactor.init(
        .v3,
        limits,
        .{ .max_inputs = 2, .max_total_pages = 3 },
        &inputs,
        sink.writer(),
        &output_compressed,
        &output_compression,
        &output_index,
    );
    try std.testing.expectError(error.TransactionSpanLimitExceeded, compactor.compact());
    try std.testing.expectEqual(CompactorState.failed, compactor.current_state());
    try std.testing.expectEqual(@as(usize, 0), sink.written().len);
}

test "aggregate page limit does not read an extra page payload" {
    const transport = @import("transport.zig");
    const limits = Limits{
        .max_input_bytes = 4096,
        .max_output_bytes = 4096,
        .max_pages = 2,
        .max_page_size = 512,
        .max_compressed_page_size = 600,
        .max_page_index_bytes = 128,
        .max_page_index_entries = 2,
        .max_varint_bytes = 10,
        .max_transaction_span = 1,
    };
    const page_a: [512]u8 = @splat(0xa1);
    const page_b: [512]u8 = @splat(0xb2);
    const post_checksum = try test_database_checksum(&.{ page_a, page_b });
    var input_bytes: [4096]u8 = undefined;
    var input_sink = transport.SliceWriter.init(&input_bytes);
    try encode_test_input(
        limits,
        input_sink.writer(),
        test_header(1, 1, .init(0)),
        &.{ page_a, page_b },
        post_checksum,
    );
    const first_size_offset: usize = format.header_size + format.page_header_size;
    const compressed_size = @import("wire.zig").read_u32_be(
        input_sink.written()[first_size_offset..][0..format.page_size_prefix_size],
    );
    const second_header_offset = first_size_offset + format.page_size_prefix_size + compressed_size;

    var source = transport.SliceReader.init(input_sink.written());
    var page: [512]u8 = undefined;
    var compressed: [600]u8 = undefined;
    var index: [2]format.PageIndexEntry = undefined;
    var inputs = [_]CompactionInput{
        CompactionInput.init(.v3, source.reader(), &page, &compressed, &index),
    };
    var output: [4096]u8 = undefined;
    var sink = transport.SliceWriter.init(&output);
    var output_compressed: [600]u8 = undefined;
    var output_compression: lz4_block.CompressionWorkspace = undefined;
    var output_index: [2]format.PageIndexEntry = undefined;
    var compactor = try Compactor.init(
        .v3,
        limits,
        .{ .max_inputs = 1, .max_total_pages = 1 },
        &inputs,
        sink.writer(),
        &output_compressed,
        &output_compression,
        &output_index,
    );
    try std.testing.expectError(error.CompactionPageLimitExceeded, compactor.compact());
    try std.testing.expectEqual(second_header_offset + format.page_header_size, source.offset);
}

fn encode_test_input(
    limits: Limits,
    writer: Writer,
    header: format.Header,
    pages: []const [512]u8,
    post_checksum: format.Checksum,
) !void {
    var compressed: [600]u8 = undefined;
    var compression: lz4_block.CompressionWorkspace = undefined;
    var index: [4]format.PageIndexEntry = undefined;
    var encoder = try Encoder.init(.v3, limits, writer, &compressed, &compression, &index);
    try encoder.write_header(header);
    for (pages, 1..) |*page, page_number| {
        const actual_number: u32 = if (header.min_txid.value == 1)
            @intCast(page_number)
        else
            2;
        try encoder.write_page(actual_number, page);
    }
    _ = try encoder.finish(post_checksum);
}

fn test_header(min_txid: u64, max_txid: u64, pre_checksum: format.Checksum) format.Header {
    return .{
        .flags = 0,
        .page_size = 512,
        .commit = 2,
        .min_txid = .init(min_txid),
        .max_txid = .init(max_txid),
        .timestamp_ms = @intCast(max_txid),
        .pre_apply_checksum = pre_checksum,
        .wal_offset = 0,
        .wal_size = 0,
        .wal_salt_1 = 0,
        .wal_salt_2 = 0,
        .node_id = 0,
    };
}

fn test_database_checksum(pages: []const [512]u8) !format.Checksum {
    const checksum = @import("checksum.zig");
    var rolling = checksum.rolling_initial();
    for (pages, 1..) |*page, page_number| {
        rolling = try checksum.rolling_add(
            rolling,
            try checksum.checksum_page(@intCast(page_number), page),
        );
    }
    return rolling;
}

fn verify_test_output(
    limits: Limits,
    bytes: []const u8,
    first_page: [512]u8,
    second_page: [512]u8,
) !void {
    const transport = @import("transport.zig");
    var source = transport.SliceReader.init(bytes);
    var page: [512]u8 = undefined;
    var compressed: [600]u8 = undefined;
    var index: [4]format.PageIndexEntry = undefined;
    var decoder = try Decoder.init(.v3, limits, source.reader(), &page, &compressed, &index);
    _ = try decoder.next();
    try expect_test_page(try decoder.next(), 1, &first_page);
    try expect_test_page(try decoder.next(), 2, &second_page);
    switch (try decoder.next()) {
        .page_block_complete => {},
        else => return error.UnexpectedDecoderEvent,
    }
    switch (try decoder.next()) {
        .verified => {},
        else => return error.UnexpectedDecoderEvent,
    }
}

fn expect_test_page(event: @import("decoder.zig").DecoderEvent, number: u32, expected: []const u8) !void {
    switch (event) {
        .unverified_page => |page| {
            try std.testing.expectEqual(number, page.header.page_number);
            try std.testing.expectEqualSlices(u8, expected, page.data);
        },
        else => return error.UnexpectedDecoderEvent,
    }
}
