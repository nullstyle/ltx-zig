const std = @import("std");
const ltx = @import("ltx");
const wal = @import("ltx_wal");

pub const Error = error{
    InvalidLimits,
    InvalidPageSize,
    PageCountLimitExceeded,
    ResourceBudgetOverflow,
};

const flagged_size_prefix_bytes: u64 = 4;
const index_terminator_bytes: u64 = 1;
const index_size_field_bytes: u64 = @sizeOf(u64);

/// Caller-owned variable storage used by one decoder. This excludes the
/// decoder value, reader state, and encoded input storage.
pub fn decoder_workspace_bytes(limits: ltx.Limits) Error!usize {
    try validate_limits(limits);
    const page_bytes = try cast_usize(limits.max_page_size);
    const compressed_bytes = try cast_usize(limits.max_compressed_page_size);
    const index_bytes = try page_index_workspace_bytes(limits);
    return add_usize(try add_usize(page_bytes, compressed_bytes), index_bytes);
}

/// Caller-owned variable storage used by one encoder. This excludes the
/// encoder value, writer state, source pages, and encoded output storage.
pub fn encoder_workspace_bytes(limits: ltx.Limits) Error!usize {
    try validate_encoder_limits(limits);
    const compressed_bytes = try cast_usize(limits.max_compressed_page_size);
    const compression_bytes = @sizeOf(ltx.LZ4CompressionWorkspace);
    const index_bytes = try page_index_workspace_bytes(limits);
    return add_usize(try add_usize(compressed_bytes, compression_bytes), index_bytes);
}

/// Caller-owned codec storage for `input_count` decoders and one output
/// encoder. Compaction input/control values and all input/output bytes are
/// separate resources.
pub fn compactor_workspace_bytes(
    limits: ltx.Limits,
    input_count: u32,
) Error!usize {
    if (input_count == 0) return error.InvalidLimits;
    const decoder_bytes = try decoder_workspace_bytes(limits);
    const encoder_bytes = try encoder_workspace_bytes(limits);
    const count = try cast_usize(input_count);
    return add_usize(try mul_usize(count, decoder_bytes), encoder_bytes);
}

/// Staged apply owns one decoder's variable codec storage. Backend staging,
/// the final database image, and the applier value are separate resources.
pub fn staged_apply_workspace_bytes(limits: ltx.Limits) Error!usize {
    return decoder_workspace_bytes(limits);
}

/// Caller-owned variable storage for one WAL committed-page-map scan: page
/// slots, the pending-page list, its bitmap, and the result entries. The
/// reader value and the whole WAL input slice are separate resources.
pub fn wal_page_map_workspace_bytes(limits: wal.Limits) Error!usize {
    limits.validate() catch return error.InvalidLimits;
    const pages = try cast_usize(limits.max_pages);
    const slots = try mul_usize(pages, @sizeOf(wal.PageSlot));
    const pending = try mul_usize(pages, @sizeOf(u32));
    const bitmap = (pages + 7) / 8;
    const entries = try mul_usize(pages, @sizeOf(wal.PageMapEntry));
    return add_usize(try add_usize(try add_usize(slots, pending), bitmap), entries);
}

/// Exact logical database length for a commit and page size.
pub fn database_size_bytes(commit_pages: u64, page_size_bytes: u64) Error!u64 {
    return mul_u64(commit_pages, page_size_bytes);
}

/// Capacity that always permits the current fast LZ4 block encoder for a
/// valid SQLite page size.
pub fn fast_lz4_bound_bytes(page_size_bytes: u32) Error!usize {
    try validate_page_size(page_size_bytes);
    const page_bytes = try cast_usize(page_size_bytes);
    const extension_bytes = page_bytes / 255;
    return add_usize(try add_usize(page_bytes, extension_bytes), 16);
}

/// Minimum capacity accepted by the encoder for its canonical literal-block
/// fallback. Valid SQLite page sizes are always at least 512 bytes.
pub fn literal_fallback_bound_bytes(page_size_bytes: u32) Error!usize {
    try validate_page_size(page_size_bytes);
    return canonical_literal_bound_bytes(page_size_bytes);
}

/// Structural upper bound for a current flagged LTX file with `page_count`
/// pages, using the configured compressed-page and page-index byte limits.
pub fn configured_wire_bound_bytes(
    limits: ltx.Limits,
    page_count: u32,
) Error!usize {
    try validate_page_count(limits, page_count);
    const fixed_bytes = try fixed_wire_bytes(usize);
    const compressed_bytes = try cast_usize(limits.max_compressed_page_size);
    const frame_bytes = try add_usize(
        try cast_usize(ltx.page_header_size + flagged_size_prefix_bytes),
        compressed_bytes,
    );
    const pages_bytes = try mul_usize(try cast_usize(page_count), frame_bytes);
    const index_bytes = try cast_usize(limits.max_page_index_bytes);
    return add_usize(try add_usize(fixed_bytes, pages_bytes), index_bytes);
}

/// Coarse structural bound using three maximum-length index varints per page,
/// the index terminator, and its encoded-size field.
pub fn coarse_varint_wire_bound_bytes(
    limits: ltx.Limits,
    page_count: u32,
) Error!usize {
    try validate_page_count(limits, page_count);
    const fixed_bytes = try fixed_wire_bytes(usize);
    const frame_bytes = try add_usize(
        try cast_usize(ltx.page_header_size + flagged_size_prefix_bytes),
        try cast_usize(limits.max_compressed_page_size),
    );
    const pages_bytes = try mul_usize(try cast_usize(page_count), frame_bytes);
    const index_bytes = try coarse_index_bytes(limits, page_count);
    return add_usize(try add_usize(fixed_bytes, pages_bytes), index_bytes);
}

/// Maximum successful event count exposed by a decoder configured with these
/// limits: header, pages, page-block completion, and verified result.
pub fn decoder_event_budget(limits: ltx.Limits) Error!u64 {
    try validate_limits(limits);
    return add_u64(limits.max_pages, 3);
}

/// Number of backend page reads performed by the post-apply database scan.
/// The scan is absent in no-checksum mode and omits SQLite's lock page.
pub fn apply_read_callback_count(
    checksummed: bool,
    commit_pages: u32,
    page_size_bytes: u32,
) Error!u64 {
    const lock_page = ltx.lock_page_number(page_size_bytes) catch {
        return error.InvalidPageSize;
    };
    if (!checksummed) return 0;
    const omitted: u32 = @intFromBool(lock_page <= commit_pages);
    return @as(u64, commit_pages - omitted);
}

fn page_index_workspace_bytes(limits: ltx.Limits) Error!usize {
    const entries = try cast_usize(limits.max_page_index_entries);
    return mul_usize(entries, @sizeOf(ltx.PageIndexEntry));
}

fn fixed_wire_bytes(comptime Int: type) Error!Int {
    var total: Int = try cast_int(Int, ltx.header_size);
    total = try add_int(Int, total, try cast_int(Int, ltx.page_header_size));
    return add_int(Int, total, try cast_int(Int, ltx.trailer_size));
}

fn coarse_index_bytes(limits: ltx.Limits, page_count: u32) Error!usize {
    const count = try cast_usize(page_count);
    const varint_bytes = try cast_usize(limits.max_varint_bytes);
    const values = try mul_usize(count, 3);
    const entries = try mul_usize(values, varint_bytes);
    const terminator = try cast_usize(index_terminator_bytes);
    const size_field = try cast_usize(index_size_field_bytes);
    return add_usize(try add_usize(entries, terminator), size_field);
}

fn validate_page_count(limits: ltx.Limits, page_count: u32) Error!void {
    try validate_limits(limits);
    if (page_count > limits.max_pages or
        page_count > limits.max_page_index_entries)
    {
        return error.PageCountLimitExceeded;
    }
}

fn validate_limits(limits: ltx.Limits) Error!void {
    limits.validate() catch return error.InvalidLimits;
}

fn validate_encoder_limits(limits: ltx.Limits) Error!void {
    try validate_limits(limits);
    const compressed_bytes = try cast_usize(limits.max_compressed_page_size);
    const literal_bytes = try canonical_literal_bound_bytes(limits.max_page_size);
    if (compressed_bytes < literal_bytes) return error.InvalidLimits;
}

fn canonical_literal_bound_bytes(page_size_bytes: u32) Error!usize {
    const page_bytes = try cast_usize(page_size_bytes);
    const extension_bytes = (page_bytes - 15) / 255;
    return add_usize(try add_usize(page_bytes, 2), extension_bytes);
}

fn validate_page_size(page_size_bytes: u32) Error!void {
    _ = ltx.lock_page_number(page_size_bytes) catch {
        return error.InvalidPageSize;
    };
}

fn cast_usize(value: anytype) Error!usize {
    return std.math.cast(usize, value) orelse error.ResourceBudgetOverflow;
}

fn cast_int(comptime Int: type, value: anytype) Error!Int {
    return std.math.cast(Int, value) orelse error.ResourceBudgetOverflow;
}

fn add_usize(left: usize, right: usize) Error!usize {
    return add_int(usize, left, right);
}

fn add_int(comptime Int: type, left: Int, right: Int) Error!Int {
    return std.math.add(Int, left, right) catch error.ResourceBudgetOverflow;
}

fn mul_usize(left: usize, right: usize) Error!usize {
    return std.math.mul(usize, left, right) catch error.ResourceBudgetOverflow;
}

fn add_u64(left: u64, right: u64) Error!u64 {
    return std.math.add(u64, left, right) catch error.ResourceBudgetOverflow;
}

fn mul_u64(left: u64, right: u64) Error!u64 {
    return std.math.mul(u64, left, right) catch error.ResourceBudgetOverflow;
}
