const std = @import("std");
const Error = @import("format.zig").Error;

// Fast encoder algorithm copyright (c) 2015 Pierre Curto, BSD-3-Clause.
// It follows pierrec/lz4 v4.1.23's operation and update order exactly.
// See LICENSE.pierrec-lz4 and docs/upstream.md for attribution and pinning.

const minimum_match_length: usize = 4;
const length_nibble_max: usize = 15;
const extension_byte_max: usize = 255;
const window_log: usize = 16;
const window_size: usize = 1 << window_log;
const window_mask: usize = window_size - 1;
const hash_log: usize = 16;
const hash_size: usize = 1 << hash_log;
const match_find_limit: usize = 10 + minimum_match_length;
const adaptive_skip_log: usize = 7;

/// Fixed reusable match state for one encoder. Contents may start undefined;
/// each independent block resets its occupancy bitmap before reading entries.
pub const CompressionWorkspace = extern struct {
    table: [hash_size]u16 = undefined,
    in_use: [hash_size / 32]u32 = @splat(0),

    fn reset(self: *CompressionWorkspace) void {
        @memset(&self.in_use, 0);
    }

    fn get(self: *const CompressionWorkspace, hash_value: u32, source_index: usize) isize {
        const hash_index: usize = @intCast(hash_value & (hash_size - 1));
        var position: isize = 0;
        const bit: u5 = @intCast(hash_index % 32);
        if (self.in_use[hash_index / 32] & (@as(u32, 1) << bit) != 0) {
            position = self.table[hash_index];
        }
        position += @intCast(source_index & ~window_mask);
        if (position >= @as(isize, @intCast(source_index))) {
            position -= window_size;
        }
        return position;
    }

    fn put(self: *CompressionWorkspace, hash_value: u32, source_index: usize) void {
        const hash_index: usize = @intCast(hash_value & (hash_size - 1));
        self.table[hash_index] = @truncate(source_index);
        const bit: u5 = @intCast(hash_index % 32);
        self.in_use[hash_index / 32] |= @as(u32, 1) << bit;
    }
};

comptime {
    std.debug.assert(@sizeOf(CompressionWorkspace) == 139_264);
    std.debug.assert(@alignOf(CompressionWorkspace) == @alignOf(u32));
}

const SearchResult = union(enum) {
    match: struct {
        source_index: usize,
        offset: usize,
    },
    miss: usize,
};

pub fn compress_bound(input_length: u32) u32 {
    const length: u64 = input_length;
    const bound = length + length / extension_byte_max + 16;
    std.debug.assert(bound <= std.math.maxInt(u32));
    return @intCast(bound);
}

pub fn literal_bound(input_length: u32) u32 {
    const length: u64 = input_length;
    const extension: u64 = if (length < length_nibble_max)
        0
    else
        1 + (length - length_nibble_max) / extension_byte_max;
    const bound = 1 + extension + length;
    std.debug.assert(bound <= std.math.maxInt(u32));
    return @intCast(bound);
}

pub fn encode_literal(input: []const u8, output: []u8) Error![]const u8 {
    if (input.len > std.math.maxInt(u32)) return error.CompressedPageLimitExceeded;
    const required: usize = literal_bound(@intCast(input.len));
    if (output.len < required) return error.WorkspaceTooSmall;

    const literal_nibble: u8 = @intCast(@min(input.len, length_nibble_max));
    output[0] = literal_nibble << 4;
    var output_index: usize = 1;
    if (input.len >= length_nibble_max) {
        var remaining = input.len - length_nibble_max;
        while (remaining >= extension_byte_max) : (remaining -= extension_byte_max) {
            output[output_index] = extension_byte_max;
            output_index += 1;
        }
        output[output_index] = @intCast(remaining);
        output_index += 1;
    }
    @memcpy(output[output_index..][0..input.len], input);
    output_index += input.len;
    std.debug.assert(output_index == required);
    return output[0..output_index];
}

pub fn encode(
    input: []const u8,
    output: []u8,
    compression_workspace: *CompressionWorkspace,
) Error![]const u8 {
    if (input.len > std.math.maxInt(u32)) return error.CompressedPageLimitExceeded;
    const input_length: u32 = @intCast(input.len);
    if (output.len < compress_bound(input_length)) {
        return encode_literal(input, output);
    }
    compression_workspace.reset();
    return encode_fast(input, output, compression_workspace);
}

fn encode_fast(
    input: []const u8,
    output: []u8,
    compression_workspace: *CompressionWorkspace,
) Error![]const u8 {
    var source_index: usize = 0;
    var output_index: usize = 0;
    var anchor: usize = 0;
    const search_end = input.len -| match_find_limit;

    while (input.len > match_find_limit and source_index < search_end) {
        switch (search(input, compression_workspace, source_index, anchor)) {
            .miss => |next_source_index| source_index = next_source_index,
            .match => |found| {
                source_index = found.source_index;
                var literal_length = source_index - anchor;
                var match_length = minimum_match_length;
                extend_match_backwards(
                    input,
                    &source_index,
                    found.offset,
                    &literal_length,
                    &match_length,
                );
                const match_base = source_index + minimum_match_length;
                source_index += match_length;
                extend_match_forwards(input, &source_index, found.offset, search_end);
                const encoded_match_length = source_index - match_base;
                try emit_match(
                    output,
                    &output_index,
                    input[anchor..][0..literal_length],
                    found.offset,
                    encoded_match_length,
                );
                anchor = source_index;
                if (source_index >= search_end) break;
                compression_workspace.put(
                    block_hash(read_u64_le(input, source_index - 2)),
                    source_index - 2,
                );
            },
        }
    }
    try emit_last_literals(output, &output_index, input[anchor..]);
    return output[0..output_index];
}

fn search(
    input: []const u8,
    compression_workspace: *CompressionWorkspace,
    initial_source_index: usize,
    anchor: usize,
) SearchResult {
    var source_index = initial_source_index;
    const matched = read_u64_le(input, source_index);
    const first_hash = block_hash(matched);
    const second_hash = block_hash(matched >> 8);
    const first_reference = compression_workspace.get(first_hash, source_index);
    const second_reference = compression_workspace.get(second_hash, source_index + 1);
    compression_workspace.put(first_hash, source_index);
    compression_workspace.put(second_hash, source_index + 1);

    if (matches_at(input, @truncate(matched), first_reference, source_index)) {
        return match_result(source_index, first_reference);
    }
    const third_hash = block_hash(matched >> 16);
    const third_reference = compression_workspace.get(third_hash, source_index + 2);
    source_index += 1;
    if (matches_at(input, @truncate(matched >> 8), second_reference, source_index)) {
        return match_result(source_index, second_reference);
    }
    source_index += 1;
    compression_workspace.put(third_hash, source_index);
    if (matches_at(input, @truncate(matched >> 16), third_reference, source_index)) {
        return match_result(source_index, third_reference);
    }
    return .{ .miss = source_index + 2 + ((source_index - anchor) >> adaptive_skip_log) };
}

fn match_result(source_index: usize, reference: isize) SearchResult {
    const signed_source_index: isize = @intCast(source_index);
    return .{ .match = .{
        .source_index = source_index,
        .offset = @intCast(signed_source_index - reference),
    } };
}

fn matches_at(
    input: []const u8,
    value: u32,
    reference: isize,
    source_index: usize,
) bool {
    if (reference < 0) return false;
    const reference_index: usize = @intCast(reference);
    const offset = source_index - reference_index;
    if (offset == 0 or offset >= window_size) return false;
    return value == std.mem.readInt(u32, input[reference_index..][0..4], .little);
}

fn extend_match_backwards(
    input: []const u8,
    source_index: *usize,
    offset: usize,
    literal_length: *usize,
    match_length: *usize,
) void {
    var target: isize = @as(isize, @intCast(source_index.* - offset)) - 1;
    while (literal_length.* > 0 and target >= 0 and
        input[source_index.* - 1] == input[@intCast(target)])
    {
        source_index.* -= 1;
        target -= 1;
        literal_length.* -= 1;
        match_length.* += 1;
    }
}

fn extend_match_forwards(
    input: []const u8,
    source_index: *usize,
    offset: usize,
    search_end: usize,
) void {
    while (source_index.* + 8 <= search_end) {
        const difference = read_u64_le(input, source_index.*) ^
            read_u64_le(input, source_index.* - offset);
        if (difference == 0) {
            source_index.* += 8;
        } else {
            source_index.* += @as(usize, @intCast(@ctz(difference) >> 3));
            break;
        }
    }
}

fn emit_match(
    output: []u8,
    output_index: *usize,
    literals: []const u8,
    offset: usize,
    encoded_match_length: usize,
) Error!void {
    const token_index = try reserve(output, output_index, 1);
    output[token_index] = @intCast(@min(encoded_match_length, length_nibble_max));
    if (literals.len < length_nibble_max) {
        output[token_index] |= @as(u8, @intCast(literals.len)) << 4;
    } else {
        output[token_index] |= 0xf0;
        try write_length(output, output_index, literals.len - length_nibble_max);
    }
    const literal_index = try reserve(output, output_index, literals.len);
    @memcpy(output[literal_index..][0..literals.len], literals);
    const offset_index = try reserve(output, output_index, 2);
    std.mem.writeInt(u16, output[offset_index..][0..2], @intCast(offset), .little);
    if (encoded_match_length >= length_nibble_max) {
        try write_length(output, output_index, encoded_match_length - length_nibble_max);
    }
}

fn emit_last_literals(
    output: []u8,
    output_index: *usize,
    literals: []const u8,
) Error!void {
    const token_index = try reserve(output, output_index, 1);
    output[token_index] = @as(u8, @intCast(@min(literals.len, length_nibble_max))) << 4;
    if (literals.len >= length_nibble_max) {
        try write_length(output, output_index, literals.len - length_nibble_max);
    }
    const literal_index = try reserve(output, output_index, literals.len);
    @memcpy(output[literal_index..][0..literals.len], literals);
}

fn write_length(output: []u8, output_index: *usize, initial_length: usize) Error!void {
    var length = initial_length;
    while (length >= extension_byte_max) : (length -= extension_byte_max) {
        const index = try reserve(output, output_index, 1);
        output[index] = extension_byte_max;
    }
    const index = try reserve(output, output_index, 1);
    output[index] = @intCast(length);
}

fn reserve(output: []u8, output_index: *usize, length: usize) Error!usize {
    const end = std.math.add(usize, output_index.*, length) catch {
        return error.WorkspaceTooSmall;
    };
    if (end > output.len) return error.WorkspaceTooSmall;
    const start = output_index.*;
    output_index.* = end;
    return start;
}

fn block_hash(value: u64) u32 {
    const prime_6_bytes: u64 = 227_718_039_650_203;
    return @truncate(((value << 16) *% prime_6_bytes) >> (64 - hash_log));
}

fn read_u64_le(input: []const u8, offset: usize) u64 {
    return std.mem.readInt(u64, input[offset..][0..8], .little);
}

pub fn decode(input: []const u8, output: []u8) Error!void {
    if (input.len == 0) return error.InvalidLZ4Block;
    var input_index: usize = 0;
    var output_index: usize = 0;
    var sequence_count: usize = 0;

    while (input_index < input.len) {
        if (sequence_count >= input.len) return error.InvalidLZ4Block;
        sequence_count += 1;
        const token = input[input_index];
        input_index += 1;

        const literal_base: usize = token >> 4;
        const literal_length = try read_length(input, &input_index, literal_base);
        try copy_literals(input, &input_index, output, &output_index, literal_length);
        if (input_index == input.len) {
            if (token & 0x0f != 0) return error.InvalidLZ4Block;
            break;
        }

        if (input.len - input_index < 2) return error.InvalidLZ4Block;
        const offset = @as(usize, input[input_index]) |
            (@as(usize, input[input_index + 1]) << 8);
        input_index += 2;
        if (offset == 0 or offset > output_index) return error.InvalidLZ4Block;

        const match_base: usize = token & 0x0f;
        const match_extra = try read_length(input, &input_index, match_base);
        const match_length = std.math.add(usize, match_extra, minimum_match_length) catch {
            return error.InvalidLZ4Block;
        };
        try copy_match(output, &output_index, offset, match_length);
    }
    if (output_index != output.len) return error.DecompressedSizeMismatch;
}

fn read_length(input: []const u8, input_index: *usize, base: usize) Error!usize {
    if (base != length_nibble_max) return base;
    var length = base;
    var extension_count: usize = 0;
    while (true) {
        if (input_index.* >= input.len) return error.InvalidLZ4Block;
        if (extension_count >= input.len) return error.InvalidLZ4Block;
        extension_count += 1;
        const byte = input[input_index.*];
        input_index.* += 1;
        length = std.math.add(usize, length, byte) catch return error.InvalidLZ4Block;
        if (byte != extension_byte_max) return length;
    }
}

fn copy_literals(
    input: []const u8,
    input_index: *usize,
    output: []u8,
    output_index: *usize,
    length: usize,
) Error!void {
    const input_end = std.math.add(usize, input_index.*, length) catch {
        return error.InvalidLZ4Block;
    };
    const output_end = std.math.add(usize, output_index.*, length) catch {
        return error.InvalidLZ4Block;
    };
    if (input_end > input.len or output_end > output.len) return error.InvalidLZ4Block;
    @memcpy(output[output_index.*..output_end], input[input_index.*..input_end]);
    input_index.* = input_end;
    output_index.* = output_end;
}

fn copy_match(output: []u8, output_index: *usize, offset: usize, length: usize) Error!void {
    const output_end = std.math.add(usize, output_index.*, length) catch {
        return error.InvalidLZ4Block;
    };
    if (output_end > output.len) return error.InvalidLZ4Block;
    var copied: usize = 0;
    while (copied < length) : (copied += 1) {
        const source_index = output_index.* - offset;
        output[output_index.*] = output[source_index];
        output_index.* += 1;
    }
    std.debug.assert(output_index.* == output_end);
}

test "literal encoder round trips the maximum SQLite page" {
    var page: [65_536]u8 = undefined;
    for (&page, 0..) |*byte, index| byte.* = @truncate(index *% 131);
    var compressed: [65_794]u8 = undefined;
    const encoded = try encode_literal(&page, &compressed);
    try std.testing.expectEqual(@as(usize, literal_bound(page.len)), encoded.len);
    var decoded: [65_536]u8 = undefined;
    try decode(encoded, &decoded);
    try std.testing.expectEqualSlices(u8, &page, &decoded);
}

test "fast encoder matches pinned Celld and pierrec vectors" {
    const repeated_hex =
        "1f810100ffffffdc000200000200b08181818181818181818181";
    const periodic_hex =
        "4f616263640400ffffffdc00ec03c0616263646162636461626364";
    var expected_repeated: [repeated_hex.len / 2]u8 = undefined;
    var expected_periodic: [periodic_hex.len / 2]u8 = undefined;
    _ = try std.fmt.hexToBytes(&expected_repeated, repeated_hex);
    _ = try std.fmt.hexToBytes(&expected_periodic, periodic_hex);

    var compression_workspace: CompressionWorkspace = .{};
    var compressed: [compress_bound(1024)]u8 = undefined;
    const repeated: [1024]u8 = @splat(0x81);
    const encoded_repeated = try encode(&repeated, &compressed, &compression_workspace);
    try std.testing.expectEqualSlices(u8, &expected_repeated, encoded_repeated);

    const periodic = "abcd" ** 256;
    const encoded_periodic = try encode(periodic, &compressed, &compression_workspace);
    try std.testing.expectEqualSlices(u8, &expected_periodic, encoded_periodic);
}

test "fast encoder matches the pinned match-find boundary vectors" {
    const fourteen_hex = "e06161616161616161616161616161";
    const fifteen_hex = "10610100a061616161616161616161";
    var expected_fourteen: [fourteen_hex.len / 2]u8 = undefined;
    var expected_fifteen: [fifteen_hex.len / 2]u8 = undefined;
    _ = try std.fmt.hexToBytes(&expected_fourteen, fourteen_hex);
    _ = try std.fmt.hexToBytes(&expected_fifteen, fifteen_hex);
    var compression_workspace: CompressionWorkspace = .{};
    var compressed: [compress_bound(15)]u8 = undefined;

    const encoded_fourteen = try encode(
        "a" ** 14,
        &compressed,
        &compression_workspace,
    );
    try std.testing.expectEqualSlices(u8, &expected_fourteen, encoded_fourteen);
    const encoded_fifteen = try encode(
        "a" ** 15,
        &compressed,
        &compression_workspace,
    );
    try std.testing.expectEqualSlices(u8, &expected_fifteen, encoded_fifteen);
}

test "fast encoder resets match state between independent blocks" {
    var compression_workspace: CompressionWorkspace = .{};
    var polluting_page: [65_536]u8 = undefined;
    var state: u32 = 0x1234_5678;
    for (&polluting_page) |*byte| {
        state = state *% 1_664_525 +% 1_013_904_223;
        byte.* = @truncate(state >> 24);
    }
    var compressed: [compress_bound(65_536)]u8 = undefined;
    _ = try encode(&polluting_page, &compressed, &compression_workspace);

    const expected_hex =
        "1f810100ffffffdc000200000200b08181818181818181818181";
    var expected: [expected_hex.len / 2]u8 = undefined;
    _ = try std.fmt.hexToBytes(&expected, expected_hex);
    const repeated: [1024]u8 = @splat(0x81);
    const encoded = try encode(&repeated, &compressed, &compression_workspace);
    try std.testing.expectEqualSlices(u8, &expected, encoded);
}

test "fast encoder matches the maximum incompressible Go known answer" {
    var page: [65_536]u8 = undefined;
    var state: u32 = 0x1234_5678;
    for (&page) |*byte| {
        state = state *% 1_664_525 +% 1_013_904_223;
        byte.* = @truncate(state >> 24);
    }
    var compression_workspace: CompressionWorkspace = .{};
    var compressed: [compress_bound(page.len)]u8 = undefined;
    const encoded = try encode(&page, &compressed, &compression_workspace);
    try std.testing.expectEqual(@as(usize, 65_794), encoded.len);

    try expect_sha256(
        encoded,
        "ae1e39e44b3496203d0fc1205292cb24a96fe928638a3cd7f12e1d709426af12",
    );
}

test "fast encoder matches compressible Go and Celld known answers" {
    var compression_workspace: CompressionWorkspace = .{};
    var compressed: [compress_bound(65_536)]u8 = undefined;

    const zeros: [65_536]u8 = @splat(0);
    const encoded_zeros = try encode(&zeros, &compressed, &compression_workspace);
    try std.testing.expectEqual(@as(usize, 279), encoded_zeros.len);
    try expect_sha256(
        encoded_zeros,
        "0f10e473b2d34bdc0b2483c2596d90f91e3e543950e69ae05d47c71fa5e70f6e",
    );

    var mixed: [512]u8 = undefined;
    var state: u32 = 0x1234_5678;
    for (&mixed) |*byte| {
        state = state *% 1_664_525 +% 1_013_904_223;
        byte.* = @truncate(state >> 24);
    }
    var chunk_index: usize = 0;
    var chunk_start: usize = 0;
    while (chunk_start < mixed.len) : (chunk_start += 97) {
        const chunk_end = @min(chunk_start + 97, mixed.len);
        if (chunk_index % 2 == 0) @memset(mixed[chunk_start..chunk_end], 0x5a);
        chunk_index += 1;
    }
    const encoded_mixed = try encode(&mixed, &compressed, &compression_workspace);
    try std.testing.expectEqual(@as(usize, 239), encoded_mixed.len);
    try expect_sha256(
        encoded_mixed,
        "3338ef8872692c0ebf75beed52a60c8c4974743dfefe31a5f1cbb0136458b2f7",
    );
}

test "fast encoder round trips varied page and boundary sizes" {
    const page_sizes = [_]usize{ 0, 1, 14, 15, 16, 270, 512, 1024, 4096, 65_536 };
    var input: [65_536]u8 = undefined;
    var compressed: [compress_bound(65_536)]u8 = undefined;
    var decoded: [65_536]u8 = undefined;
    var compression_workspace: CompressionWorkspace = .{};

    for (page_sizes) |page_size| {
        var state: u32 = 0x1234_5678;
        for (input[0..page_size]) |*byte| {
            state = state *% 1_664_525 +% 1_013_904_223;
            byte.* = @truncate(state >> 24);
        }
        var chunk_index: usize = 0;
        var chunk_start: usize = 0;
        while (chunk_start < page_size) : (chunk_start += 97) {
            const chunk_end = @min(chunk_start + 97, page_size);
            if (chunk_index % 2 == 0) @memset(input[chunk_start..chunk_end], 0x5a);
            chunk_index += 1;
        }

        const encoded = try encode(
            input[0..page_size],
            &compressed,
            &compression_workspace,
        );
        try decode(encoded, decoded[0..page_size]);
        try std.testing.expectEqualSlices(u8, input[0..page_size], decoded[0..page_size]);
        try std.testing.expect(encoded.len <= compress_bound(@intCast(page_size)));
    }
}

test "encoder falls back to literals below the canonical fast bound" {
    const page_size: u32 = 512;
    const page: [page_size]u8 = @splat(0);
    var compression_workspace: CompressionWorkspace = .{};
    var fallback: [literal_bound(page_size)]u8 = undefined;
    var expected_bytes: [literal_bound(page_size)]u8 = undefined;

    const encoded = try encode(&page, &fallback, &compression_workspace);
    const expected = try encode_literal(&page, &expected_bytes);
    try std.testing.expectEqualSlices(u8, expected, encoded);
    try std.testing.expectEqual(@as(usize, literal_bound(page_size)), encoded.len);

    var almost_fast: [compress_bound(page_size) - 1]u8 = undefined;
    const encoded_almost_fast = try encode(&page, &almost_fast, &compression_workspace);
    try std.testing.expectEqualSlices(u8, expected, encoded_almost_fast);

    var short: [literal_bound(page_size) - 1]u8 = undefined;
    try std.testing.expectError(
        error.WorkspaceTooSmall,
        encode(&page, &short, &compression_workspace),
    );
}

test "compression bounds cover the maximum SQLite page" {
    try std.testing.expectEqual(@as(usize, 139_264), @sizeOf(CompressionWorkspace));
    try std.testing.expectEqual(@as(u32, 530), compress_bound(512));
    try std.testing.expectEqual(@as(u32, 65_809), compress_bound(65_536));
    try std.testing.expectEqual(@as(u32, 65_794), literal_bound(65_536));
}

test "decoder supports overlapping LZ4 matches" {
    const compressed = [_]u8{ 0x44, 'a', 'b', 'c', 'd', 0x04, 0x00 };
    var decoded: [12]u8 = undefined;
    try decode(&compressed, &decoded);
    try std.testing.expectEqualStrings("abcdabcdabcd", &decoded);
}

test "decoder accepts a compressed block emitted by pinned Go LZ4" {
    const compressed = [_]u8{
        0x1f, 0x00, 0x01, 0x00, 0xff, 0xda, 0x00, 0x02,
        0x00, 0x00, 0x02, 0x00, 0xb0, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    };
    var decoded: [512]u8 = undefined;
    try decode(&compressed, &decoded);
    try std.testing.expectEqualSlices(u8, &(@as([512]u8, @splat(0))), &decoded);
}

test "decoder rejects zero offsets and wrong output sizes" {
    var decoded: [8]u8 = undefined;
    try std.testing.expectError(
        error.InvalidLZ4Block,
        decode(&.{ 0x10, 'a', 0x00, 0x00 }, &decoded),
    );
    try std.testing.expectError(error.DecompressedSizeMismatch, decode("\x10a", &decoded));
}

test "terminal literal sequence cannot claim a missing match" {
    var decoded: [1]u8 = undefined;
    try std.testing.expectError(error.InvalidLZ4Block, decode("\x11a", &decoded));
}

fn expect_sha256(input: []const u8, expected_hex: []const u8) !void {
    var expected: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    _ = try std.fmt.hexToBytes(&expected, expected_hex);
    var actual: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(input, &actual, .{});
    try std.testing.expectEqualSlices(u8, &expected, &actual);
}
