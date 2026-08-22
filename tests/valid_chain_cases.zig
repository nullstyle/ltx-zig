const std = @import("std");
const ltx = @import("ltx");
const manifest = @import("valid_chain_manifest.zig");

pub const max_page_bytes: usize = 65_536;
pub const max_compressed_bytes: usize = 65_809;
pub const max_database_pages: usize = 5;
pub const max_inputs: usize = 3;
pub const max_total_page_events: u64 = 9;
pub const max_file_bytes: usize = 384 * 1024;
pub const database_capacity_bytes: usize = max_database_pages * max_page_bytes;

pub const codec_limits = ltx.Limits{
    .max_input_bytes = max_file_bytes,
    .max_output_bytes = max_file_bytes,
    .max_pages = max_database_pages,
    .max_page_size = max_page_bytes,
    .max_compressed_page_size = max_compressed_bytes,
    .max_page_index_bytes = max_file_bytes,
    .max_page_index_entries = max_database_pages,
    .max_varint_bytes = 10,
    .max_transaction_span = max_inputs,
};

pub const compaction_limits = ltx.CompactionLimits{
    .max_inputs = max_inputs,
    .max_total_pages = max_total_page_events,
};

pub const apply_limits = ltx.ApplyLimits{
    .max_database_pages = max_database_pages,
    .max_database_bytes = database_capacity_bytes,
};

const legacy_snapshot = @embedFile("fixtures/go_v3_legacy_unflagged.ltx");
const legacy_snapshot_post = ltx.Checksum.init(0xefb1_f44f_ecd9_9000);
const zero_position = ltx.Position{
    .txid = .init(0),
    .post_apply_checksum = .init(0),
};

pub const CaseKind = manifest.CaseKind;
pub const all = manifest.all;
pub const name = manifest.name;

pub const EncodedInput = struct {
    bytes: [max_file_bytes]u8 = undefined,
    length_bytes: usize = 0,

    pub fn slice(self: *const EncodedInput) []const u8 {
        return self.bytes[0..self.length_bytes];
    }
};

pub const BuiltChain = struct {
    kind: CaseKind = undefined,
    inputs: [max_inputs]EncodedInput = @splat(.{}),
    input_count: usize = 0,
    expected_database: [database_capacity_bytes]u8 = @splat(0),
    expected_length_bytes: usize = 0,
    expected_positions: [max_inputs]ltx.Position = @splat(zero_position),
    expected_page_size: u32 = 0,
    expected_commit: u32 = 0,
    expected_timestamp_ms: i64 = 0,
    expected_header_flags: u32 = 0,
    expected_hash_hex: []const u8 = "",

    pub fn expected_slice(self: *const BuiltChain) []const u8 {
        return self.expected_database[0..self.expected_length_bytes];
    }
};

pub const Compacted = struct {
    bytes: [max_file_bytes]u8 = undefined,
    length_bytes: usize = 0,
    verified: ltx.VerifiedLTX = undefined,

    pub fn slice(self: *const Compacted) []const u8 {
        return self.bytes[0..self.length_bytes];
    }
};

const PageUpdate = struct {
    page_number: u32,
    fill: u8,
};

const Transition = struct {
    commit: u32,
    updates: []const PageUpdate,
};

const CaseSpec = struct {
    page_size: u32,
    no_checksum: bool,
    legacy_prefix: bool = false,
    transitions: []const Transition,
    expected_hash_hex: []const u8,
};

const grow_transitions = [_]Transition{
    .{ .commit = 2, .updates = &.{
        .{ .page_number = 1, .fill = 0x11 },
        .{ .page_number = 2, .fill = 0x12 },
    } },
    .{ .commit = 5, .updates = &.{
        .{ .page_number = 1, .fill = 0x21 },
        .{ .page_number = 3, .fill = 0x23 },
        .{ .page_number = 4, .fill = 0x24 },
        .{ .page_number = 5, .fill = 0x25 },
    } },
    .{ .commit = 5, .updates = &.{
        .{ .page_number = 2, .fill = 0x32 },
        .{ .page_number = 5, .fill = 0x35 },
    } },
};

const shrink_transitions = [_]Transition{
    .{ .commit = 5, .updates = &.{
        .{ .page_number = 1, .fill = 0x41 },
        .{ .page_number = 2, .fill = 0x42 },
        .{ .page_number = 3, .fill = 0x43 },
        .{ .page_number = 4, .fill = 0x44 },
        .{ .page_number = 5, .fill = 0x45 },
    } },
    .{ .commit = 5, .updates = &.{
        .{ .page_number = 2, .fill = 0x52 },
        .{ .page_number = 5, .fill = 0x55 },
    } },
    .{ .commit = 3, .updates = &.{
        .{ .page_number = 1, .fill = 0x61 },
        .{ .page_number = 3, .fill = 0x63 },
    } },
};

const max_page_transitions = [_]Transition{
    .{ .commit = 2, .updates = &.{
        .{ .page_number = 1, .fill = 0x71 },
        .{ .page_number = 2, .fill = 0x72 },
    } },
    .{ .commit = 1, .updates = &.{
        .{ .page_number = 1, .fill = 0x81 },
    } },
};

const deletion_transitions = [_]Transition{
    .{ .commit = 3, .updates = &.{
        .{ .page_number = 1, .fill = 0x91 },
        .{ .page_number = 2, .fill = 0x92 },
        .{ .page_number = 3, .fill = 0x93 },
    } },
    .{ .commit = 0, .updates = &.{} },
};

const legacy_tail_transitions = [_]Transition{
    .{ .commit = 1, .updates = &.{
        .{ .page_number = 1, .fill = 0xa1 },
    } },
};

pub fn build(kind: CaseKind, chain: *BuiltChain) !void {
    const spec = case_spec(kind);
    chain.* = .{
        .kind = kind,
        .expected_page_size = spec.page_size,
        .expected_header_flags = if (spec.no_checksum)
            ltx.header_flag_no_checksum
        else
            0,
        .expected_hash_hex = spec.expected_hash_hex,
    };

    var previous_post = ltx.Checksum.init(0);
    if (spec.legacy_prefix) {
        try add_legacy_prefix(chain);
        previous_post = legacy_snapshot_post;
    }
    for (spec.transitions) |transition| {
        if (chain.input_count >= max_inputs) return error.TestInputLimitExceeded;
        const txid: u64 = @intCast(chain.input_count + 1);
        try apply_transition(chain, spec.page_size, transition);
        const post = if (spec.no_checksum)
            ltx.Checksum.init(0)
        else
            try database_checksum(chain.expected_slice(), spec.page_size);
        try encode_transition(chain, spec, transition, txid, previous_post, post);
        chain.expected_positions[chain.input_count] = .{
            .txid = .init(txid),
            .post_apply_checksum = post,
        };
        chain.input_count += 1;
        previous_post = post;
    }
    if (chain.input_count == 0) return error.TestInputRequired;
    if (chain.input_count != manifest.input_count(kind)) return error.TestInputCountMismatch;
    chain.expected_commit = @intCast(chain.expected_length_bytes / spec.page_size);
    chain.expected_timestamp_ms = timestamp_ms(kind, @intCast(chain.input_count));
}

pub fn compact(chain: *const BuiltChain, result: *Compacted) !void {
    if (chain.input_count == 0 or chain.input_count > max_inputs) {
        return error.TestInputLimitExceeded;
    }
    var workspaces: [max_inputs]InputWorkspace = undefined;
    var inputs: [max_inputs]ltx.CompactionInput = undefined;
    for (0..chain.input_count) |index| {
        inputs[index] = workspaces[index].input(chain.inputs[index].slice());
    }

    var sink = ltx.SliceWriter.init(&result.bytes);
    var compressed: [max_compressed_bytes]u8 = undefined;
    var compression: ltx.LZ4CompressionWorkspace = undefined;
    var index: [max_database_pages]ltx.PageIndexEntry = undefined;
    var compactor = try ltx.Compactor.init(
        .v3,
        codec_limits,
        compaction_limits,
        inputs[0..chain.input_count],
        sink.writer(),
        &compressed,
        &compression,
        &index,
    );
    result.verified = try compactor.compact();
    if (compactor.current_state() != .finished) return error.TestCompactorDidNotFinish;
    result.length_bytes = sink.written().len;
    if (result.verified.byte_count != result.length_bytes) return error.TestLengthMismatch;
}

const InputWorkspace = struct {
    source: ltx.SliceReader = undefined,
    page: [max_page_bytes]u8 = undefined,
    compressed: [max_compressed_bytes]u8 = undefined,
    index: [max_database_pages]ltx.PageIndexEntry = undefined,

    fn input(self: *InputWorkspace, bytes: []const u8) ltx.CompactionInput {
        self.source = ltx.SliceReader.init(bytes);
        return ltx.CompactionInput.init(
            .v3,
            self.source.reader(),
            &self.page,
            &self.compressed,
            &self.index,
        );
    }
};

fn case_spec(kind: CaseKind) CaseSpec {
    return switch (kind) {
        .checked_grow_512 => .{
            .page_size = 512,
            .no_checksum = false,
            .transitions = &grow_transitions,
            .expected_hash_hex = "c89c89ca0c8c8a5ad990add46f40c64237cc847535b7c46a1338671f24727203",
        },
        .checked_sparse_shrink_4096 => .{
            .page_size = 4096,
            .no_checksum = false,
            .transitions = &shrink_transitions,
            .expected_hash_hex = "748180e5b2dcef3c390c2b9b26700b20df220c43455bc52f75d41e769b6f7adc",
        },
        .no_checksum_max_page_shrink_65536 => .{
            .page_size = 65_536,
            .no_checksum = true,
            .transitions = &max_page_transitions,
            .expected_hash_hex = "1f2d41b212c74e121e69ba1f71cdf254ce7b478dfb675bca590a1bb9c952354f",
        },
        .checked_delete_1024 => .{
            .page_size = 1024,
            .no_checksum = false,
            .transitions = &deletion_transitions,
            .expected_hash_hex = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        },
        .legacy_current_512 => .{
            .page_size = 512,
            .no_checksum = false,
            .legacy_prefix = true,
            .transitions = &legacy_tail_transitions,
            .expected_hash_hex = "a84f98fa7bc9cfbb6ee11fc4eb67c730d9648d3a32a4933b289d5cc28fc72865",
        },
    };
}

fn add_legacy_prefix(chain: *BuiltChain) !void {
    if (legacy_snapshot.len > max_file_bytes) return error.TestInputLimitExceeded;
    @memcpy(chain.inputs[0].bytes[0..legacy_snapshot.len], legacy_snapshot);
    chain.inputs[0].length_bytes = legacy_snapshot.len;
    chain.expected_length_bytes = 512;
    @memset(chain.expected_database[0..chain.expected_length_bytes], 0);
    chain.expected_positions[0] = .{
        .txid = .init(1),
        .post_apply_checksum = legacy_snapshot_post,
    };
    chain.input_count = 1;
}

fn apply_transition(
    chain: *BuiltChain,
    page_size_u32: u32,
    transition: Transition,
) !void {
    if (transition.commit > max_database_pages) return error.TestDatabasePageLimitExceeded;
    if (transition.updates.len > max_database_pages) return error.TestPageEventLimitExceeded;
    const page_size: usize = @intCast(page_size_u32);
    const target_length = std.math.mul(usize, transition.commit, page_size) catch
        return error.TestDatabaseSizeLimitExceeded;
    if (target_length > chain.expected_database.len) {
        return error.TestDatabaseSizeLimitExceeded;
    }
    const changed_start = @min(target_length, chain.expected_length_bytes);
    const changed_end = @max(target_length, chain.expected_length_bytes);
    @memset(chain.expected_database[changed_start..changed_end], 0);
    chain.expected_length_bytes = target_length;

    var previous_page_number: u32 = 0;
    for (transition.updates) |update| {
        if (update.page_number <= previous_page_number or update.page_number > transition.commit) {
            return error.TestInvalidPageSequence;
        }
        const page_index: usize = @intCast(update.page_number - 1);
        const offset = std.math.mul(usize, page_index, page_size) catch
            return error.TestDatabaseSizeLimitExceeded;
        @memset(chain.expected_database[offset .. offset + page_size], update.fill);
        previous_page_number = update.page_number;
    }
}

fn encode_transition(
    chain: *BuiltChain,
    spec: CaseSpec,
    transition: Transition,
    txid: u64,
    pre: ltx.Checksum,
    post: ltx.Checksum,
) !void {
    const input = &chain.inputs[chain.input_count];
    var sink = ltx.SliceWriter.init(&input.bytes);
    var compressed: [max_compressed_bytes]u8 = undefined;
    var compression: ltx.LZ4CompressionWorkspace = undefined;
    var index: [max_database_pages]ltx.PageIndexEntry = undefined;
    var encoder = try ltx.Encoder.init(
        .v3,
        codec_limits,
        sink.writer(),
        &compressed,
        &compression,
        &index,
    );
    try encoder.write_header(make_header(chain.kind, spec, transition.commit, txid, pre));
    const page_size: usize = @intCast(spec.page_size);
    for (transition.updates) |update| {
        const page_index: usize = @intCast(update.page_number - 1);
        const offset = page_index * page_size;
        try encoder.write_page(
            update.page_number,
            chain.expected_database[offset .. offset + page_size],
        );
    }
    const verified = try encoder.finish(post);
    input.length_bytes = sink.written().len;
    if (verified.byte_count != input.length_bytes) return error.TestLengthMismatch;
}

fn make_header(
    kind: CaseKind,
    spec: CaseSpec,
    commit: u32,
    txid: u64,
    pre: ltx.Checksum,
) ltx.Header {
    const metadata_base = @as(u64, @intFromEnum(kind) + 1) * 1000 + txid * 10;
    return .{
        .flags = if (spec.no_checksum) ltx.header_flag_no_checksum else 0,
        .page_size = spec.page_size,
        .commit = commit,
        .min_txid = .init(txid),
        .max_txid = .init(txid),
        .timestamp_ms = timestamp_ms(kind, txid),
        .pre_apply_checksum = if (spec.no_checksum) .init(0) else pre,
        .wal_offset = @intCast(metadata_base),
        .wal_size = @intCast(metadata_base + 50),
        .wal_salt_1 = @intCast(metadata_base + 1),
        .wal_salt_2 = @intCast(metadata_base + 2),
        .node_id = metadata_base + 3,
    };
}

fn timestamp_ms(kind: CaseKind, txid: u64) i64 {
    return @as(i64, @intFromEnum(kind) + 1) * 100_000 + @as(i64, @intCast(txid));
}

fn database_checksum(database: []const u8, page_size_u32: u32) !ltx.Checksum {
    const page_size: usize = @intCast(page_size_u32);
    if (database.len % page_size != 0) return error.TestDatabaseSizeMismatch;
    const page_count = database.len / page_size;
    if (page_count > max_database_pages) return error.TestDatabasePageLimitExceeded;
    var checksum = ltx.rolling_checksum_initial();
    for (0..page_count) |page_index| {
        const offset = page_index * page_size;
        checksum = try ltx.rolling_checksum_add(
            checksum,
            try ltx.checksum_page(
                @intCast(page_index + 1),
                database[offset .. offset + page_size],
            ),
        );
    }
    return checksum;
}
