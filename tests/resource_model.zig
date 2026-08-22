const std = @import("std");
const ltx = @import("ltx");
const resource_model = @import("resource_model");

test "workspace formulas use symbolic public type sizes" {
    const limits = test_limits(4096, 4128, 256);
    const index_bytes = @as(usize, limits.max_page_index_entries) *
        @sizeOf(ltx.PageIndexEntry);
    const expected_decoder = @as(usize, limits.max_page_size) +
        limits.max_compressed_page_size + index_bytes;
    const expected_encoder = @as(usize, limits.max_compressed_page_size) +
        @sizeOf(ltx.LZ4CompressionWorkspace) + index_bytes;

    try std.testing.expectEqual(
        expected_decoder,
        try resource_model.decoder_workspace_bytes(limits),
    );
    try std.testing.expectEqual(
        expected_encoder,
        try resource_model.encoder_workspace_bytes(limits),
    );
    try std.testing.expectEqual(
        4 * expected_decoder + expected_encoder,
        try resource_model.compactor_workspace_bytes(limits, 4),
    );
    try std.testing.expectEqual(
        expected_decoder,
        try resource_model.staged_apply_workspace_bytes(limits),
    );
}

test "workspace formulas cover minimum and maximum SQLite page sizes" {
    const cases = [_]struct {
        page_size_bytes: u32,
        compressed_bytes: u32,
    }{
        .{ .page_size_bytes = 512, .compressed_bytes = 530 },
        .{ .page_size_bytes = 65_536, .compressed_bytes = 65_809 },
    };
    for (cases) |case| {
        const limits = test_limits(case.page_size_bytes, case.compressed_bytes, 1);
        const index_bytes = @sizeOf(ltx.PageIndexEntry);
        try std.testing.expectEqual(
            @as(usize, case.page_size_bytes) + case.compressed_bytes + index_bytes,
            try resource_model.decoder_workspace_bytes(limits),
        );
        try std.testing.expectEqual(
            @as(usize, case.compressed_bytes) +
                @sizeOf(ltx.LZ4CompressionWorkspace) + index_bytes,
            try resource_model.encoder_workspace_bytes(limits),
        );
    }
}

test "LZ4 bounds match minimum and maximum page known answers" {
    const cases = [_]struct {
        page_size_bytes: u32,
        fast_bytes: usize,
        literal_bytes: usize,
    }{
        .{ .page_size_bytes = 512, .fast_bytes = 530, .literal_bytes = 515 },
        .{ .page_size_bytes = 65_536, .fast_bytes = 65_809, .literal_bytes = 65_794 },
    };
    for (cases) |case| {
        const fast_bytes = try resource_model.fast_lz4_bound_bytes(case.page_size_bytes);
        const literal_bytes = try resource_model.literal_fallback_bound_bytes(
            case.page_size_bytes,
        );
        try std.testing.expectEqual(case.fast_bytes, fast_bytes);
        try std.testing.expectEqual(case.literal_bytes, literal_bytes);
        try std.testing.expect(literal_bytes <= fast_bytes);
    }
    try std.testing.expectError(
        error.InvalidPageSize,
        resource_model.fast_lz4_bound_bytes(1000),
    );
}

test "wire bounds include current flagged framing and bounded index" {
    var limits = test_limits(4096, 4128, 256);
    limits.max_page_index_bytes = 8192;
    limits.max_varint_bytes = 10;
    const page_count: u32 = 32;
    const fixed_bytes = @as(usize, ltx.header_size) +
        ltx.page_header_size + ltx.trailer_size;
    const frame_bytes = @as(usize, ltx.page_header_size) + 4 +
        limits.max_compressed_page_size;
    const configured_index_bytes: usize = @intCast(limits.max_page_index_bytes);
    const coarse_index_bytes = @as(usize, page_count) * 3 *
        limits.max_varint_bytes + 1 + @sizeOf(u64);

    try std.testing.expectEqual(
        fixed_bytes + page_count * frame_bytes + configured_index_bytes,
        try resource_model.configured_wire_bound_bytes(limits, page_count),
    );
    try std.testing.expectEqual(
        fixed_bytes + page_count * frame_bytes + coarse_index_bytes,
        try resource_model.coarse_varint_wire_bound_bytes(limits, page_count),
    );
}

test "wire bounds enforce page and index-entry limits" {
    var limits = test_limits(512, 530, 2);
    limits.max_pages = 1;
    try std.testing.expectError(
        error.PageCountLimitExceeded,
        resource_model.configured_wire_bound_bytes(limits, 2),
    );

    limits.max_pages = 2;
    limits.max_page_index_entries = 1;
    try std.testing.expectError(
        error.PageCountLimitExceeded,
        resource_model.coarse_varint_wire_bound_bytes(limits, 2),
    );
}

test "resource arithmetic reports overflow" {
    try std.testing.expectError(
        error.ResourceBudgetOverflow,
        resource_model.database_size_bytes(std.math.maxInt(u64), 2),
    );

    var limits = test_limits(65_536, std.math.maxInt(u32), std.math.maxInt(u32));
    limits.max_pages = std.math.maxInt(u32);
    limits.max_page_index_bytes = std.math.maxInt(u64);
    try std.testing.expectError(
        error.ResourceBudgetOverflow,
        resource_model.configured_wire_bound_bytes(limits, std.math.maxInt(u32)),
    );
    try std.testing.expectError(
        error.ResourceBudgetOverflow,
        resource_model.compactor_workspace_bytes(limits, std.math.maxInt(u32)),
    );
}

test "compactor workspace requires at least one input" {
    try std.testing.expectError(
        error.InvalidLimits,
        resource_model.compactor_workspace_bytes(test_limits(4096, 4128, 1), 0),
    );
}

test "database and decoder event formulas are exact" {
    const limits = test_limits(4096, 4128, 256);
    try std.testing.expectEqual(
        @as(u64, 256 * 4096),
        try resource_model.database_size_bytes(256, 4096),
    );
    try std.testing.expectEqual(
        @as(u64, limits.max_pages) + 3,
        try resource_model.decoder_event_budget(limits),
    );
}

test "apply read count excludes lock page only for checksummed scans" {
    const page_size_bytes: u32 = 65_536;
    const lock_page = try ltx.lock_page_number(page_size_bytes);
    try std.testing.expectEqual(
        @as(u64, lock_page - 1),
        try resource_model.apply_read_callback_count(
            true,
            lock_page - 1,
            page_size_bytes,
        ),
    );
    try std.testing.expectEqual(
        @as(u64, lock_page - 1),
        try resource_model.apply_read_callback_count(true, lock_page, page_size_bytes),
    );
    try std.testing.expectEqual(
        @as(u64, lock_page),
        try resource_model.apply_read_callback_count(true, lock_page + 1, page_size_bytes),
    );
    try std.testing.expectEqual(
        @as(u64, 0),
        try resource_model.apply_read_callback_count(false, lock_page + 1, page_size_bytes),
    );
    try std.testing.expectError(
        error.InvalidPageSize,
        resource_model.apply_read_callback_count(true, 1, 1000),
    );
}

test "invalid codec limits are rejected" {
    var limits = test_limits(512, 530, 1);
    limits.max_page_size = 511;
    try std.testing.expectError(
        error.InvalidLimits,
        resource_model.decoder_workspace_bytes(limits),
    );
    limits.max_page_size = 65_537;
    try std.testing.expectError(
        error.InvalidLimits,
        resource_model.encoder_workspace_bytes(limits),
    );
}

test "encoder and compactor budgets require canonical literal capacity" {
    const decoder_valid = test_limits(65_536, 1, 1);
    _ = try resource_model.decoder_workspace_bytes(decoder_valid);
    _ = try resource_model.staged_apply_workspace_bytes(decoder_valid);
    try std.testing.expectError(
        error.InvalidLimits,
        resource_model.encoder_workspace_bytes(decoder_valid),
    );
    try std.testing.expectError(
        error.InvalidLimits,
        resource_model.compactor_workspace_bytes(decoder_valid, 1),
    );

    const ceiling = test_limits(1000, 1005, 1);
    _ = try resource_model.encoder_workspace_bytes(ceiling);
}

fn test_limits(
    page_size_bytes: u32,
    compressed_bytes: u32,
    index_entries: u32,
) ltx.Limits {
    return .{
        .max_input_bytes = std.math.maxInt(u64),
        .max_output_bytes = std.math.maxInt(u64),
        .max_pages = index_entries,
        .max_page_size = page_size_bytes,
        .max_compressed_page_size = compressed_bytes,
        .max_page_index_bytes = std.math.maxInt(u64),
        .max_page_index_entries = index_entries,
        .max_varint_bytes = 10,
        .max_transaction_span = std.math.maxInt(u64),
    };
}
