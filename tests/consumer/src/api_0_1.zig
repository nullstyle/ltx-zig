//! Source-level compatibility contract for the supported 0.1 public API.
//! This deliberately checks names, field construction, enum/error tags, and
//! function signatures without freezing layout, alignment, or the absence of
//! future additive declarations.

const std = @import("std");
const ltx = @import("ltx");
const ltx_sqlite = @import("ltx_sqlite");

fn require_function(comptime function_type: type, function: function_type) void {
    _ = function;
}

fn require_field_type(
    comptime container: type,
    comptime field_name: []const u8,
    comptime expected: type,
) void {
    if (@FieldType(container, field_name) != expected) {
        @compileError("supported 0.1 public field type changed");
    }
}

const CoreCallbacks = struct {
    fn read(_: *anyopaque, destination: []u8) error{InputFailure}!usize {
        _ = destination;
        return 0;
    }

    fn at_end(_: *anyopaque) error{InputFailure}!bool {
        return true;
    }

    fn write_all(_: *anyopaque, bytes: []const u8) error{OutputFailure}!void {
        _ = bytes;
    }

    fn begin(
        _: *anyopaque,
        _: ltx.ApplyPlan,
    ) error{ApplyBeginFailure}!ltx.ApplyCurrent {
        return .{
            .position = zero_position,
            .page_size = null,
        };
    }

    fn stage_page(_: *anyopaque, _: ltx.StagedPage) error{ApplyStageFailure}!void {}

    fn read_page(
        _: *anyopaque,
        _: u32,
        destination: []u8,
    ) error{ApplyReadFailure}!void {
        @memset(destination, 0);
    }

    fn publish(
        _: *anyopaque,
        _: ltx.ApplyCurrent,
        _: ltx.VerifiedLTX,
    ) error{
        ApplyPublishFailure,
        ApplyPublishIndeterminate,
        NonContiguousTransition,
        DivergentHistory,
        DatabasePageSizeMismatch,
    }!void {}

    fn abort(_: *anyopaque) void {}
};

const LifecycleCallbacks = struct {
    fn quiesce(_: *anyopaque) error{QuiesceFailure}!void {}
    fn release(_: *anyopaque) void {}
};

const zero_position: ltx.Position = .{
    .txid = .init(0),
    .post_apply_checksum = .init(0),
};

test "0.1 core value fields retain exact source types" {
    require_field_type(ltx.TXID, "value", u64);
    require_field_type(ltx.Checksum, "value", u64);
    require_field_type(ltx.Position, "txid", ltx.TXID);
    require_field_type(ltx.Position, "post_apply_checksum", ltx.Checksum);
    require_field_type(ltx.Header, "flags", u32);
    require_field_type(ltx.Header, "page_size", u32);
    require_field_type(ltx.Header, "commit", u32);
    require_field_type(ltx.Header, "min_txid", ltx.TXID);
    require_field_type(ltx.Header, "max_txid", ltx.TXID);
    require_field_type(ltx.Header, "timestamp_ms", i64);
    require_field_type(ltx.Header, "pre_apply_checksum", ltx.Checksum);
    require_field_type(ltx.Header, "wal_offset", i64);
    require_field_type(ltx.Header, "wal_size", i64);
    require_field_type(ltx.Header, "wal_salt_1", u32);
    require_field_type(ltx.Header, "wal_salt_2", u32);
    require_field_type(ltx.Header, "node_id", u64);
    require_field_type(ltx.PageHeader, "page_number", u32);
    require_field_type(ltx.PageHeader, "flags", u16);
    require_field_type(ltx.PageIndexEntry, "page_number", u32);
    require_field_type(ltx.PageIndexEntry, "frame_offset_bytes", u64);
    require_field_type(ltx.PageIndexEntry, "frame_size_bytes", u64);
    require_field_type(ltx.Trailer, "post_apply_checksum", ltx.Checksum);
    require_field_type(ltx.Trailer, "file_checksum", ltx.Checksum);
    require_field_type(ltx.UnverifiedPage, "header", ltx.PageHeader);
    require_field_type(ltx.UnverifiedPage, "data", []const u8);
    require_field_type(ltx.VerifiedLTX, "format_version", ltx.FormatVersion);
    require_field_type(ltx.VerifiedLTX, "header", ltx.Header);
    require_field_type(ltx.VerifiedLTX, "trailer", ltx.Trailer);
    require_field_type(ltx.VerifiedLTX, "page_count", u32);
    require_field_type(ltx.VerifiedLTX, "byte_count", u64);
}

test "0.1 limit and orchestration fields retain exact source types" {
    require_field_type(ltx.Limits, "max_input_bytes", u64);
    require_field_type(ltx.Limits, "max_output_bytes", u64);
    require_field_type(ltx.Limits, "max_pages", u32);
    require_field_type(ltx.Limits, "max_page_size", u32);
    require_field_type(ltx.Limits, "max_compressed_page_size", u32);
    require_field_type(ltx.Limits, "max_page_index_bytes", u64);
    require_field_type(ltx.Limits, "max_page_index_entries", u32);
    require_field_type(ltx.Limits, "max_varint_bytes", u8);
    require_field_type(ltx.Limits, "max_transaction_span", u64);
    require_field_type(ltx.CompactionLimits, "max_inputs", u32);
    require_field_type(ltx.CompactionLimits, "max_total_pages", u64);
    require_field_type(ltx.ApplyLimits, "max_database_pages", u32);
    require_field_type(ltx.ApplyLimits, "max_database_bytes", u64);
    require_field_type(ltx.ApplyPlan, "format_version", ltx.FormatVersion);
    require_field_type(ltx.ApplyPlan, "mode", ltx.ApplyMode);
    require_field_type(ltx.ApplyPlan, "header", ltx.Header);
    require_field_type(ltx.ApplyPlan, "final_database_size_bytes", u64);
    require_field_type(ltx.ApplyCurrent, "position", ltx.Position);
    require_field_type(ltx.ApplyCurrent, "page_size", ?u32);
    require_field_type(ltx.StagedPage, "page_number", u32);
    require_field_type(ltx.StagedPage, "offset_bytes", u64);
    require_field_type(ltx.StagedPage, "data", []const u8);
}

test "0.1 transport and callback fields retain exact source types" {
    require_field_type(ltx.Reader, "context", *anyopaque);
    require_field_type(ltx.Reader, "read_fn", *const fn (*anyopaque, []u8) error{InputFailure}!usize);
    require_field_type(ltx.Reader, "at_end_fn", *const fn (*anyopaque) error{InputFailure}!bool);
    require_field_type(ltx.Reader, "backing_bytes", ?[]const u8);
    require_field_type(ltx.Writer, "context", *anyopaque);
    require_field_type(ltx.Writer, "write_all_fn", *const fn (*anyopaque, []const u8) error{OutputFailure}!void);
    require_field_type(ltx.Writer, "backing_bytes", ?[]u8);
    require_field_type(ltx.ApplyBackend, "context", *anyopaque);
    require_field_type(ltx.ApplyBackend, "begin_fn", *const fn (*anyopaque, ltx.ApplyPlan) error{ApplyBeginFailure}!ltx.ApplyCurrent);
    require_field_type(ltx.ApplyBackend, "stage_page_fn", *const fn (*anyopaque, ltx.StagedPage) error{ApplyStageFailure}!void);
    require_field_type(ltx.ApplyBackend, "read_page_fn", *const fn (*anyopaque, u32, []u8) error{ApplyReadFailure}!void);
    require_field_type(ltx.ApplyBackend, "publish_fn", *const fn (*anyopaque, ltx.ApplyCurrent, ltx.VerifiedLTX) error{
        ApplyPublishFailure,
        ApplyPublishIndeterminate,
        NonContiguousTransition,
        DivergentHistory,
        DatabasePageSizeMismatch,
    }!void);
    require_field_type(ltx.ApplyBackend, "abort_fn", *const fn (*anyopaque) void);
    require_field_type(ltx.ApplyBackend, "backing_bytes", ?[]u8);
}

test "0.1 sqlite value and callback fields retain exact source types" {
    require_field_type(ltx_sqlite.Lifecycle, "context", *anyopaque);
    require_field_type(ltx_sqlite.Lifecycle, "quiesce_fn", *const fn (*anyopaque) error{QuiesceFailure}!void);
    require_field_type(ltx_sqlite.Lifecycle, "release_fn", *const fn (*anyopaque) void);
    require_field_type(ltx_sqlite.Current, "position", ltx.Position);
    require_field_type(ltx_sqlite.Current, "page_size", u32);
    require_field_type(ltx_sqlite.Current, "database_size_bytes", u64);
    require_field_type(ltx_sqlite.Current, "generation", u64);
    require_field_type(ltx_sqlite.Current, "slot", ltx_sqlite.Slot);
    require_field_type(ltx_sqlite.GenerationAccessWorkspace, "path_bytes", [ltx_sqlite.max_generation_path_bytes]u8);
    require_field_type(ltx_sqlite.GenerationAccessWorkspace, "uri_bytes", [ltx_sqlite.max_generation_uri_bytes]u8);
    require_field_type(ltx_sqlite.SQLiteOpenSpec, "uri", [:0]const u8);
    require_field_type(ltx_sqlite.SQLiteOpenSpec, "required_flags", c_int);
    require_field_type(ltx_sqlite.SQLiteOpenSpec, "query_only_sql", [:0]const u8);
}

test "0.1 core constants, values, and data types remain source compatible" {
    try std.testing.expectEqual(@as(u8, 3), @intFromEnum(ltx.FormatVersion.v3));
    try std.testing.expectEqual(@as(u64, 0x8000_0000_0000_0000), ltx.checksum_flag);
    try std.testing.expectEqual(@as(u32, 2), ltx.header_flag_no_checksum);
    try std.testing.expectEqual(@as(u16, 1), ltx.page_header_flag_size);
    try std.testing.expectEqual(@as(u32, 100), ltx.header_size);
    try std.testing.expectEqual(@as(u32, 6), ltx.page_header_size);
    try std.testing.expectEqual(@as(u32, 16), ltx.trailer_size);
    try std.testing.expectEqual(@as(u64, 0x4000_0000), ltx.sqlite_pending_byte);
    try std.testing.expectEqual(@as(u32, 262_145), try ltx.lock_page_number(4096));

    const limits: ltx.Limits = .{
        .max_input_bytes = 4096,
        .max_output_bytes = 4096,
        .max_pages = 1,
        .max_page_size = 512,
        .max_compressed_page_size = 515,
        .max_page_index_bytes = 9,
        .max_page_index_entries = 1,
        .max_varint_bytes = 10,
        .max_transaction_span = 1,
    };
    const header: ltx.Header = .{
        .flags = 0,
        .page_size = 512,
        .commit = 1,
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
    const page_header: ltx.PageHeader = .{ .page_number = 1, .flags = 0 };
    const index_entry: ltx.PageIndexEntry = .{
        .page_number = 1,
        .frame_offset_bytes = ltx.header_size,
        .frame_size_bytes = ltx.page_header_size,
    };
    const trailer: ltx.Trailer = .{
        .post_apply_checksum = .init(ltx.checksum_flag),
        .file_checksum = .init(ltx.checksum_flag),
    };
    const unverified_page: ltx.UnverifiedPage = .{
        .header = page_header,
        .data = "",
    };
    const verified: ltx.VerifiedLTX = .{
        .format_version = .v3,
        .header = header,
        .trailer = trailer,
        .page_count = 1,
        .byte_count = ltx.header_size + ltx.page_header_size + ltx.trailer_size,
    };
    const compaction_limits: ltx.CompactionLimits = .{
        .max_inputs = 1,
        .max_total_pages = 1,
    };
    const apply_limits: ltx.ApplyLimits = .{
        .max_database_pages = 1,
        .max_database_bytes = 512,
    };
    const apply_plan: ltx.ApplyPlan = .{
        .format_version = .v3,
        .mode = .replace_snapshot,
        .header = header,
        .final_database_size_bytes = 512,
    };
    const apply_current: ltx.ApplyCurrent = .{
        .position = zero_position,
        .page_size = null,
    };
    const staged_page: ltx.StagedPage = .{
        .page_number = 1,
        .offset_bytes = 0,
        .data = "",
    };

    _ = limits;
    _ = index_entry;
    _ = unverified_page;
    _ = verified;
    _ = compaction_limits;
    _ = apply_limits;
    _ = apply_plan;
    _ = apply_current;
    _ = staged_page;
    _ = ltx.LZ4CompressionWorkspace;
}

test "0.1 core enum and error tags remain available" {
    const decoder_states = [_]ltx.DecoderState{
        .header,
        .pages,
        .page_index,
        .trailer,
        .verified,
        .failed,
    };
    const encoder_states = [_]ltx.EncoderState{
        .initialized,
        .pages,
        .index_written,
        .trailer_written,
        .finished,
        .failed,
    };
    const compactor_states = [_]ltx.CompactorState{
        .initialized,
        .compacting,
        .finished,
        .failed,
    };
    const apply_modes = [_]ltx.ApplyMode{ .contiguous, .replace_snapshot };
    const apply_states = [_]ltx.ApplyState{
        .initialized,
        .staging,
        .published,
        .recovery_required,
        .failed,
    };
    const header: ltx.Header = undefined;
    const page: ltx.UnverifiedPage = undefined;
    const verified: ltx.VerifiedLTX = undefined;
    const decoder_events = [_]ltx.DecoderEvent{
        .{ .header = header },
        .{ .unverified_page = page },
        .{ .page_block_complete = {} },
        .{ .verified = verified },
    };
    const errors = [_]ltx.Error{
        error.UnsupportedFormatVersion,
        error.UnsupportedPageEncoding,
        error.InvalidLimits,
        error.WorkspaceTooSmall,
        error.InputFailure,
        error.OutputFailure,
        error.InputLimitExceeded,
        error.OutputLimitExceeded,
        error.PageLimitExceeded,
        error.PageSizeLimitExceeded,
        error.CompressedPageLimitExceeded,
        error.PageIndexLimitExceeded,
        error.TransactionSpanLimitExceeded,
        error.TruncatedInput,
        error.TrailingBytes,
        error.InvalidMagic,
        error.InvalidHeaderFlags,
        error.InvalidPageSize,
        error.InvalidTXIDRange,
        error.InvalidChecksumFormat,
        error.InvalidPreApplyChecksum,
        error.InvalidWALMetadata,
        error.InvalidPageFlags,
        error.InvalidPageNumber,
        error.InvalidPageDataSize,
        error.PageOutOfOrder,
        error.SnapshotPageSequence,
        error.LockPagePresent,
        error.InvalidCompressedSize,
        error.InvalidLZ4Block,
        error.InvalidLZ4Frame,
        error.LZ4ContentChecksumMismatch,
        error.DecompressedSizeMismatch,
        error.VarintOverflow,
        error.OverlongVarint,
        error.InvalidPageIndex,
        error.PageIndexMismatch,
        error.InvalidPageIndexSize,
        error.InvalidTrailer,
        error.ChecksumMismatch,
        error.SnapshotChecksumMismatch,
        error.DatabaseChecksumMismatch,
        error.NonContiguousTransition,
        error.DivergentHistory,
        error.DatabasePageLimitExceeded,
        error.DatabaseSizeLimitExceeded,
        error.DatabasePageSizeMismatch,
        error.ApplyBeginFailure,
        error.ApplyStageFailure,
        error.ApplyReadFailure,
        error.ApplyPublishFailure,
        error.ApplyPublishIndeterminate,
        error.CompactionInputRequired,
        error.CompactionInputLimitExceeded,
        error.CompactionPageLimitExceeded,
        error.CompactionPageSizeMismatch,
        error.CompactionChecksumModeMismatch,
        error.WorkspaceAliasing,
        error.InvalidState,
    };

    _ = ltx.FormatVersion.v3;
    _ = decoder_states;
    _ = encoder_states;
    _ = compactor_states;
    _ = apply_modes;
    _ = apply_states;
    _ = decoder_events;
    _ = errors;
}

test "0.1 transport and processing function signatures remain compatible" {
    require_function(*const fn (ltx.FormatVersion) ltx.Error!void, ltx.FormatVersion.validate);
    require_function(*const fn (u64) ltx.TXID, ltx.TXID.init);
    require_function(*const fn (u64) ltx.Checksum, ltx.Checksum.init);
    require_function(*const fn (ltx.Checksum) bool, ltx.Checksum.has_valid_flag);
    require_function(*const fn (ltx.Header) bool, ltx.Header.is_snapshot);
    require_function(*const fn (ltx.Header) bool, ltx.Header.no_checksum);
    require_function(*const fn (ltx.Header) ltx.Error!ltx.Position, ltx.Header.pre_apply_position);
    require_function(*const fn (ltx.Header, ltx.Position) ltx.Error!void, ltx.Header.check_contiguous);
    require_function(*const fn (ltx.Header, ltx.Limits) ltx.Error!void, ltx.Header.validate);
    require_function(*const fn (ltx.PageHeader) bool, ltx.PageHeader.is_terminator);
    require_function(*const fn (ltx.PageHeader) ltx.Error!void, ltx.PageHeader.validate);
    require_function(*const fn (ltx.Trailer, ltx.Header) ltx.Error!void, ltx.Trailer.validate);
    require_function(*const fn (ltx.VerifiedLTX) ltx.Error!ltx.Position, ltx.VerifiedLTX.pre_apply_position);
    require_function(*const fn (ltx.VerifiedLTX) ltx.Position, ltx.VerifiedLTX.post_apply_position);
    require_function(*const fn (ltx.VerifiedLTX, ltx.Position) ltx.Error!void, ltx.VerifiedLTX.check_contiguous);
    require_function(*const fn (ltx.Limits) error{InvalidLimits}!void, ltx.Limits.validate);
    require_function(*const fn (u32, []const u8) ltx.Error!ltx.Checksum, ltx.checksum_page);
    require_function(*const fn () ltx.Checksum, ltx.rolling_checksum_initial);
    require_function(*const fn (ltx.Checksum, ltx.Checksum) ltx.Error!ltx.Checksum, ltx.rolling_checksum_add);
    require_function(*const fn (u32) ltx.Error!u32, ltx.lock_page_number);

    const read_fn: *const fn (*anyopaque, []u8) error{InputFailure}!usize = CoreCallbacks.read;
    const at_end_fn: *const fn (*anyopaque) error{InputFailure}!bool = CoreCallbacks.at_end;
    const write_all_fn: *const fn (*anyopaque, []const u8) error{OutputFailure}!void = CoreCallbacks.write_all;
    var context: u8 = 0;
    const reader: ltx.Reader = .{
        .context = &context,
        .read_fn = read_fn,
        .at_end_fn = at_end_fn,
        .backing_bytes = null,
    };
    const writer: ltx.Writer = .{
        .context = &context,
        .write_all_fn = write_all_fn,
        .backing_bytes = null,
    };
    var destination: [1]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 0), try reader.read(&destination));
    try std.testing.expect(try reader.at_end());
    try writer.write_all("");

    require_function(*const fn (ltx.Reader, []u8) error{InputFailure}!usize, ltx.Reader.read);
    require_function(*const fn (ltx.Reader) error{InputFailure}!bool, ltx.Reader.at_end);
    require_function(*const fn (ltx.Writer, []const u8) error{OutputFailure}!void, ltx.Writer.write_all);
    require_function(*const fn ([]const u8) ltx.SliceReader, ltx.SliceReader.init);
    require_function(*const fn (*ltx.SliceReader) ltx.Reader, ltx.SliceReader.reader);
    require_function(*const fn ([]u8) ltx.SliceWriter, ltx.SliceWriter.init);
    require_function(*const fn (*ltx.SliceWriter) ltx.Writer, ltx.SliceWriter.writer);
    require_function(*const fn (*const ltx.SliceWriter) []const u8, ltx.SliceWriter.written);

    require_function(
        *const fn (ltx.FormatVersion, ltx.Limits, ltx.Reader, []u8, []u8, []ltx.PageIndexEntry) ltx.Error!ltx.Decoder,
        ltx.Decoder.init,
    );
    require_function(*const fn (*ltx.Decoder) ltx.Error!ltx.DecoderEvent, ltx.Decoder.next);
    require_function(*const fn (*const ltx.Decoder) ltx.DecoderState, ltx.Decoder.current_state);
    require_function(*const fn (*const ltx.Decoder) ltx.FormatVersion, ltx.Decoder.selected_format_version);
    require_function(*const fn (*const ltx.Decoder) u64, ltx.Decoder.event_budget);

    require_function(
        *const fn (ltx.FormatVersion, ltx.Limits, ltx.Writer, []u8, *ltx.LZ4CompressionWorkspace, []ltx.PageIndexEntry) ltx.Error!ltx.Encoder,
        ltx.Encoder.init,
    );
    require_function(*const fn (*ltx.Encoder, ltx.Header) ltx.Error!void, ltx.Encoder.write_header);
    require_function(*const fn (*ltx.Encoder, u32, []const u8) ltx.Error!void, ltx.Encoder.write_page);
    require_function(*const fn (*ltx.Encoder, ltx.Checksum) ltx.Error!ltx.VerifiedLTX, ltx.Encoder.finish);
    require_function(*const fn (*const ltx.Encoder) ltx.EncoderState, ltx.Encoder.current_state);
    require_function(*const fn (*const ltx.Encoder) ltx.FormatVersion, ltx.Encoder.selected_format_version);

    require_function(*const fn (ltx.CompactionLimits) error{InvalidLimits}!void, ltx.CompactionLimits.validate);
    require_function(
        *const fn (ltx.Reader, []u8, []u8, []ltx.PageIndexEntry) ltx.CompactionInput,
        ltx.CompactionInput.init,
    );
    require_function(
        *const fn (ltx.FormatVersion, ltx.Limits, ltx.CompactionLimits, []ltx.CompactionInput, ltx.Writer, []u8, *ltx.LZ4CompressionWorkspace, []ltx.PageIndexEntry) ltx.Error!ltx.Compactor,
        ltx.Compactor.init,
    );
    require_function(*const fn (*ltx.Compactor) ltx.Error!ltx.VerifiedLTX, ltx.Compactor.compact);
    require_function(*const fn (*const ltx.Compactor) ltx.CompactorState, ltx.Compactor.current_state);
    require_function(*const fn (*const ltx.Compactor) ltx.FormatVersion, ltx.Compactor.selected_format_version);

    const compaction_input = ltx.CompactionInput.init(reader, &.{}, &.{}, &.{});
    _ = compaction_input;
}

test "0.1 staged apply contract preserves callback and method signatures" {
    require_function(*const fn (ltx.ApplyLimits) error{InvalidLimits}!void, ltx.ApplyLimits.validate);

    const begin_fn: *const fn (*anyopaque, ltx.ApplyPlan) error{ApplyBeginFailure}!ltx.ApplyCurrent = CoreCallbacks.begin;
    const stage_page_fn: *const fn (*anyopaque, ltx.StagedPage) error{ApplyStageFailure}!void = CoreCallbacks.stage_page;
    const read_page_fn: *const fn (*anyopaque, u32, []u8) error{ApplyReadFailure}!void = CoreCallbacks.read_page;
    const publish_fn: *const fn (*anyopaque, ltx.ApplyCurrent, ltx.VerifiedLTX) error{
        ApplyPublishFailure,
        ApplyPublishIndeterminate,
        NonContiguousTransition,
        DivergentHistory,
        DatabasePageSizeMismatch,
    }!void = CoreCallbacks.publish;
    const abort_fn: *const fn (*anyopaque) void = CoreCallbacks.abort;
    var context: u8 = 0;
    const backend: ltx.ApplyBackend = .{
        .context = &context,
        .begin_fn = begin_fn,
        .stage_page_fn = stage_page_fn,
        .read_page_fn = read_page_fn,
        .publish_fn = publish_fn,
        .abort_fn = abort_fn,
        .backing_bytes = null,
    };
    _ = backend;

    require_function(
        *const fn (ltx.FormatVersion, ltx.Limits, ltx.ApplyLimits, ltx.ApplyMode, ltx.Reader, ltx.ApplyBackend, []u8, []u8, []ltx.PageIndexEntry) ltx.Error!ltx.StagedApplier,
        ltx.StagedApplier.init,
    );
    require_function(*const fn (*const ltx.StagedApplier) ltx.ApplyState, ltx.StagedApplier.current_state);
    require_function(*const fn (*ltx.StagedApplier) ltx.Error!ltx.VerifiedLTX, ltx.StagedApplier.apply);
}

test "0.1 sqlite constants, values, data types, enums, and errors remain compatible" {
    try std.testing.expectEqualStrings("ltx.current", ltx_sqlite.manifest_name);
    try std.testing.expectEqualStrings("ltx.current.tmp", ltx_sqlite.manifest_temporary_name);
    try std.testing.expectEqualStrings("ltx.lock", ltx_sqlite.lock_name);
    try std.testing.expectEqualStrings("ltx.sqlite.a", ltx_sqlite.database_a_name);
    try std.testing.expectEqualStrings("ltx.sqlite.b", ltx_sqlite.database_b_name);
    try std.testing.expectEqual(@as(u8, 0), @intFromEnum(ltx_sqlite.Slot.a));
    try std.testing.expectEqual(@as(u8, 1), @intFromEnum(ltx_sqlite.Slot.b));
    const path_capacity: usize = ltx_sqlite.max_generation_path_bytes;
    const uri_capacity: usize = ltx_sqlite.max_generation_uri_bytes;
    try std.testing.expect(path_capacity > 0);
    try std.testing.expect(uri_capacity > path_capacity);

    const failures = [_]ltx_sqlite.Failure{
        .none,
        .invalid_workspace,
        .invalid_state,
        .invalid_database_path,
        .unsupported_platform,
        .store_busy,
        .quiesce_failure,
        .manifest_corrupt,
        .database_missing,
        .database_size_mismatch,
        .sidecar_present,
        .invalid_sqlite_database,
        .database_page_size_mismatch,
        .database_checksum_mismatch,
        .generation_overflow,
        .fault_injected,
        .io_failure,
    };
    const states = [_]ltx_sqlite.StoreState{
        .idle,
        .acquiring,
        .staging,
        .recovery_required,
    };
    const slots = [_]ltx_sqlite.Slot{ .a, .b };
    const errors = [_]ltx_sqlite.Error{
        error.InvalidWorkspace,
        error.InvalidState,
        error.InvalidDatabasePath,
        error.UnsupportedPlatform,
        error.StoreBusy,
        error.QuiesceFailure,
        error.ManifestCorrupt,
        error.DatabaseMissing,
        error.DatabaseSizeMismatch,
        error.SidecarPresent,
        error.InvalidSQLiteDatabase,
        error.DatabasePageSizeMismatch,
        error.DatabaseChecksumMismatch,
        error.GenerationOverflow,
        error.FaultInjected,
        error.IOFailure,
    };
    _ = failures;
    _ = states;
    _ = slots;
    _ = errors;

    const current: ltx_sqlite.Current = .{
        .position = .{
            .txid = .init(1),
            .post_apply_checksum = .init(ltx.checksum_flag),
        },
        .page_size = 4096,
        .database_size_bytes = 4096,
        .generation = 1,
        .slot = .a,
    };
    const storage: ltx_sqlite.GenerationAccessStorage = .{};
    const workspace: ltx_sqlite.GenerationAccessWorkspace = .{};
    const uri: [:0]const u8 = "file:ltx.sqlite.a?mode=ro&immutable=1";
    const open_spec: ltx_sqlite.SQLiteOpenSpec = .{ .uri = uri };
    try std.testing.expectEqualStrings(ltx_sqlite.database_a_name, current.database_name());
    try std.testing.expectEqual(@as(c_int, 0x41), open_spec.required_flags);
    try std.testing.expectEqualStrings("PRAGMA query_only=ON", open_spec.query_only_sql);
    try std.testing.expectEqual(path_capacity, workspace.path_bytes.len);
    try std.testing.expectEqual(uri_capacity, workspace.uri_bytes.len);
    _ = storage;
    _ = ltx_sqlite.GenerationAccess;
}

test "0.1 sqlite lifecycle, store, and generation-access signatures remain compatible" {
    const quiesce_fn: *const fn (*anyopaque) error{QuiesceFailure}!void = LifecycleCallbacks.quiesce;
    const release_fn: *const fn (*anyopaque) void = LifecycleCallbacks.release;
    var context: u8 = 0;
    const lifecycle: ltx_sqlite.Lifecycle = .{
        .context = &context,
        .quiesce_fn = quiesce_fn,
        .release_fn = release_fn,
    };
    const options: ltx_sqlite.Options = .{};
    _ = lifecycle;
    _ = options;

    require_function(*const fn (ltx_sqlite.Slot) []const u8, ltx_sqlite.Slot.database_name);
    require_function(*const fn (ltx_sqlite.Current) []const u8, ltx_sqlite.Current.database_name);
    require_function(
        *const fn (std.Io, std.Io.Dir, []u8, ltx_sqlite.Lifecycle, ltx_sqlite.Options) ltx_sqlite.Error!ltx_sqlite.Store,
        ltx_sqlite.Store.init,
    );
    require_function(*const fn (*ltx_sqlite.Store) ltx.ApplyBackend, ltx_sqlite.Store.backend);
    require_function(*const fn (*const ltx_sqlite.Store) ltx_sqlite.StoreState, ltx_sqlite.Store.current_state);
    require_function(*const fn (*const ltx_sqlite.Store) ltx_sqlite.Failure, ltx_sqlite.Store.last_failure);
    require_function(*const fn (*ltx_sqlite.Store) ltx_sqlite.Error!?ltx_sqlite.Current, ltx_sqlite.Store.current);
    require_function(
        *const fn (*ltx_sqlite.Store, *ltx_sqlite.GenerationAccessStorage, *ltx_sqlite.GenerationAccessWorkspace) ltx_sqlite.Error!?ltx_sqlite.GenerationAccess,
        ltx_sqlite.Store.acquire_generation,
    );
    require_function(*const fn (*ltx_sqlite.Store) ltx_sqlite.Error!?ltx_sqlite.Current, ltx_sqlite.Store.recover);
    require_function(*const fn (*const ltx_sqlite.GenerationAccess) ltx_sqlite.Error!ltx_sqlite.Current, ltx_sqlite.GenerationAccess.current);
    require_function(*const fn (*const ltx_sqlite.GenerationAccess) ltx_sqlite.Error!ltx_sqlite.SQLiteOpenSpec, ltx_sqlite.GenerationAccess.sqlite_open_spec);
    require_function(*const fn (*ltx_sqlite.GenerationAccess) ltx_sqlite.Error!void, ltx_sqlite.GenerationAccess.release);
}

test "0.1 production contract excludes unstable fault injection types" {
    // FaultPoint and FaultInjection are deliberately not named or structurally
    // inspected by this contract. They remain testing-only 0.x implementation
    // controls. The supported production contract is the default null option.
    const options: ltx_sqlite.Options = .{};
    try std.testing.expect(options.fault_injection == null);
}
