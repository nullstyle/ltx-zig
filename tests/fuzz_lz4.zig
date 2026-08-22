const std = @import("std");
const lz4_block = @import("lz4_block");

const snapshot_fixture = @embedFile("fixtures/go_v3_snapshot_zero_page.ltx");
const no_checksum_fixture = @embedFile("fixtures/go_v3_no_checksum.ltx");
const celld_fixture = @embedFile("fixtures/celld_v052_two_page_snapshot.ltx");
const near_lock_fixture = @embedFile("fixtures/go_v3_near_lock_page.ltx");

const lz4_output_sizes = [_]usize{
    0, 1, 3, 4, 12, 14, 15, 16, 511, 512, 513, 1024, 4095, 4096, 65_535, 65_536,
};
const max_lz4_input_bytes: usize = 1024;
const max_lz4_output_bytes: usize = 65_536;
const lz4_guard_bytes: usize = 16;
const first_lz4_poison: u8 = 0xa5;
const second_lz4_poison: u8 = 0x5a;

const lz4_fourteen = "\xe0" ++ ("a" ** 14);
const lz4_fifteen = "\x10a\x01\x00\xa0" ++ ("a" ** 10);
const lz4_extension_storm = "\xf0" ++ ("\xff" ** 32);
const lz4_seed_empty_output = indexed_slice_seed(0, "\x00");
const lz4_seed_one_literal = indexed_slice_seed(1, "\x10a");
const lz4_seed_three_literals = indexed_slice_seed(2, "\x30abc");
const lz4_seed_overlap = indexed_slice_seed(4, "\x44abcd\x04\x00");
const lz4_seed_fourteen = indexed_slice_seed(5, lz4_fourteen);
const lz4_seed_fifteen = indexed_slice_seed(6, lz4_fifteen);
const lz4_seed_zero_page = indexed_slice_seed(9, snapshot_fixture[110..134]);
const lz4_seed_celld_page = indexed_slice_seed(11, celld_fixture[110..136]);
const lz4_seed_no_checksum_page = indexed_slice_seed(13, no_checksum_fixture[110..148]);
const lz4_seed_near_lock_page = indexed_slice_seed(15, near_lock_fixture[110..389]);
const lz4_seed_zero_offset = indexed_slice_seed(3, "\x10a\x00\x00");
const lz4_seed_large_offset = indexed_slice_seed(3, "\x10a\xff\xff");
const lz4_seed_extension_storm = indexed_slice_seed(15, lz4_extension_storm);
const lz4_seed_truncated = indexed_slice_seed(7, "\x00\x01");
const lz4_corpus = [_][]const u8{
    &lz4_seed_empty_output,
    &lz4_seed_one_literal,
    &lz4_seed_three_literals,
    &lz4_seed_overlap,
    &lz4_seed_fourteen,
    &lz4_seed_fifteen,
    &lz4_seed_zero_page,
    &lz4_seed_celld_page,
    &lz4_seed_no_checksum_page,
    &lz4_seed_near_lock_page,
    &lz4_seed_zero_offset,
    &lz4_seed_large_offset,
    &lz4_seed_extension_storm,
    &lz4_seed_truncated,
};

test "raw LZ4 decoder fuzz corpus preserves bounds and results" {
    try std.testing.fuzz({}, fuzz_lz4_decoder, .{ .corpus = &lz4_corpus });
}

fn fuzz_lz4_decoder(_: void, smith: *std.testing.Smith) !void {
    const output_length = lz4_output_sizes[smith.index(lz4_output_sizes.len)];
    var input_storage: [max_lz4_input_bytes]u8 = undefined;
    const input_length: usize = smith.slice(&input_storage);
    try check_lz4_decode(input_storage[0..input_length], output_length);
}

fn check_lz4_decode(input: []const u8, output_length: usize) !void {
    const storage_bytes = max_lz4_output_bytes + 2 * lz4_guard_bytes;
    var first_storage: [storage_bytes]u8 = @splat(first_lz4_poison);
    var second_storage: [storage_bytes]u8 = @splat(second_lz4_poison);
    const first_output = first_storage[lz4_guard_bytes..][0..output_length];
    const second_output = second_storage[lz4_guard_bytes..][0..output_length];
    const first_failure = lz4_decode_failure(input, first_output);
    const second_failure = lz4_decode_failure(input, second_output);
    try std.testing.expectEqual(first_failure, second_failure);
    try expect_lz4_guards(&first_storage, output_length, first_lz4_poison);
    try expect_lz4_guards(&second_storage, output_length, second_lz4_poison);
    if (first_failure == null) {
        try std.testing.expectEqualSlices(u8, first_output, second_output);
        return;
    }
    @memset(&second_storage, first_lz4_poison);
    const replay_failure = lz4_decode_failure(input, second_output);
    try std.testing.expectEqual(first_failure, replay_failure);
    try std.testing.expectEqualSlices(u8, first_output, second_output);
    try expect_lz4_guards(&second_storage, output_length, first_lz4_poison);
}

fn lz4_decode_failure(input: []const u8, output: []u8) ?anyerror {
    lz4_block.decode(input, output) catch |err| return err;
    return null;
}

fn expect_lz4_guards(storage: []const u8, output_length: usize, poison: u8) !void {
    try std.testing.expect(std.mem.allEqual(
        u8,
        storage[0..lz4_guard_bytes],
        poison,
    ));
    const suffix_offset = lz4_guard_bytes + output_length;
    try std.testing.expect(std.mem.allEqual(
        u8,
        storage[suffix_offset..][0..lz4_guard_bytes],
        poison,
    ));
}

const max_compressor_input_bytes: u32 = 4096;
const max_fast_output_bytes: usize = lz4_block.compress_bound(max_compressor_input_bytes);
const max_literal_output_bytes: usize = lz4_block.literal_bound(max_compressor_input_bytes);
const compressor_zero_page: [512]u8 = @splat(0);
const compressor_periodic_page = "abcd" ** 256;
const compressor_mixed_page = make_mixed_page();
const compressor_seed_empty = slice_seed("");
const compressor_seed_one = slice_seed("a");
const compressor_seed_fourteen = slice_seed("a" ** 14);
const compressor_seed_fifteen = slice_seed("a" ** 15);
const compressor_seed_zero_page = slice_seed(&compressor_zero_page);
const compressor_seed_periodic_page = slice_seed(compressor_periodic_page);
const compressor_seed_mixed_page = slice_seed(&compressor_mixed_page);
const compressor_corpus = [_][]const u8{
    &compressor_seed_empty,
    &compressor_seed_one,
    &compressor_seed_fourteen,
    &compressor_seed_fifteen,
    &compressor_seed_zero_page,
    &compressor_seed_periodic_page,
    &compressor_seed_mixed_page,
};

test "raw LZ4 compressor fuzz corpus is deterministic and round trips" {
    try std.testing.fuzz({}, fuzz_lz4_compressor, .{ .corpus = &compressor_corpus });
}

fn fuzz_lz4_compressor(_: void, smith: *std.testing.Smith) !void {
    var input_storage: [max_compressor_input_bytes]u8 = undefined;
    const input_length: usize = smith.slice(&input_storage);
    try check_lz4_compression(input_storage[0..input_length]);
}

fn check_lz4_compression(input: []const u8) !void {
    var workspace: lz4_block.CompressionWorkspace = undefined;
    var first_output: [max_fast_output_bytes]u8 = @splat(0xa5);
    var second_output: [max_fast_output_bytes]u8 = @splat(0x5a);
    @memset(std.mem.asBytes(&workspace), 0xa5);
    const first_encoded = try lz4_block.encode(input, &first_output, &workspace);
    @memset(std.mem.asBytes(&workspace), 0x5a);
    const second_encoded = try lz4_block.encode(input, &second_output, &workspace);
    try std.testing.expect(first_encoded.len <= lz4_block.compress_bound(@intCast(input.len)));
    try std.testing.expectEqualSlices(u8, first_encoded, second_encoded);

    var decoded: [max_compressor_input_bytes]u8 = undefined;
    try lz4_block.decode(first_encoded, decoded[0..input.len]);
    try std.testing.expectEqualSlices(u8, input, decoded[0..input.len]);

    const literal_length: usize = lz4_block.literal_bound(@intCast(input.len));
    var literal_output: [max_literal_output_bytes]u8 = undefined;
    const literal_encoded = try lz4_block.encode(
        input,
        literal_output[0..literal_length],
        &workspace,
    );
    try std.testing.expectEqual(literal_length, literal_encoded.len);
    try lz4_block.decode(literal_encoded, decoded[0..input.len]);
    try std.testing.expectEqualSlices(u8, input, decoded[0..input.len]);

    var short_output: [max_literal_output_bytes]u8 = @splat(0x3c);
    try std.testing.expectError(
        error.WorkspaceTooSmall,
        lz4_block.encode(input, short_output[0 .. literal_length - 1], &workspace),
    );
    try std.testing.expect(std.mem.allEqual(u8, &short_output, 0x3c));
}

fn indexed_slice_seed(
    comptime selector: u64,
    comptime bytes: []const u8,
) [12 + bytes.len]u8 {
    var result: [12 + bytes.len]u8 = undefined;
    std.mem.writeInt(u64, result[0..8], selector, .little);
    std.mem.writeInt(u32, result[8..12], bytes.len, .little);
    @memcpy(result[12..], bytes);
    return result;
}

fn slice_seed(comptime bytes: []const u8) [4 + bytes.len]u8 {
    var result: [4 + bytes.len]u8 = undefined;
    std.mem.writeInt(u32, result[0..4], bytes.len, .little);
    @memcpy(result[4..], bytes);
    return result;
}

fn make_mixed_page() [max_compressor_input_bytes]u8 {
    @setEvalBranchQuota(20_000);
    var result: [max_compressor_input_bytes]u8 = undefined;
    var state: u32 = 0x1234_5678;
    for (&result, 0..) |*byte, index| {
        state = state *% 1_664_525 +% 1_013_904_223;
        byte.* = @truncate((state >> 24) ^ (index *% 131));
    }
    return result;
}
