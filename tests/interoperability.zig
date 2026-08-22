const std = @import("std");
const ltx = @import("ltx");

test "public module is available as ltx" {
    try std.testing.expectEqual(@as(u32, 100), ltx.header_size);
}

const limits = ltx.Limits{
    .max_input_bytes = 4096,
    .max_output_bytes = 4096,
    .max_pages = 8,
    .max_page_size = 65_536,
    .max_compressed_page_size = 66_000,
    .max_page_index_bytes = 1024,
    .max_page_index_entries = 8,
    .max_varint_bytes = 10,
    .max_transaction_span = 100,
};

test "decode current Go v3 flagged block fixture" {
    var fixture: [168]u8 = undefined;
    try load_fixture("fixtures/go_v3_snapshot_zero_page.ltx", &fixture);
    var source = ltx.SliceReader.init(&fixture);
    var page_workspace: [65_536]u8 = undefined;
    var compressed_workspace: [66_000]u8 = undefined;
    var index_workspace: [8]ltx.PageIndexEntry = undefined;
    var decoder = try ltx.Decoder.init(
        .v3,
        limits,
        source.reader(),
        &page_workspace,
        &compressed_workspace,
        &index_workspace,
    );

    switch (try decoder.next()) {
        .header => |header| {
            try std.testing.expectEqual(@as(u32, 512), header.page_size);
            try std.testing.expectEqual(@as(u32, 1), header.commit);
        },
        else => return error.UnexpectedDecoderEvent,
    }
    switch (try decoder.next()) {
        .unverified_page => |page| {
            try std.testing.expectEqual(@as(u32, 1), page.header.page_number);
            try std.testing.expectEqual(ltx.page_header_flag_size, page.header.flags);
            try std.testing.expectEqualSlices(u8, &(@as([512]u8, @splat(0))), page.data);
        },
        else => return error.UnexpectedDecoderEvent,
    }
    switch (try decoder.next()) {
        .page_block_complete => {},
        else => return error.UnexpectedDecoderEvent,
    }
    switch (try decoder.next()) {
        .verified => |verified| {
            try std.testing.expectEqual(@as(u32, 1), verified.page_count);
            try std.testing.expectEqual(@as(u64, 168), verified.byte_count);
            try std.testing.expectEqual(
                @as(u64, 0xefb1_f44f_ecd9_9000),
                verified.post_apply_position().post_apply_checksum.value,
            );
            try std.testing.expectEqual(
                @as(u64, 0xeb51_21d5_6d33_a656),
                verified.trailer.file_checksum.value,
            );
        },
        else => return error.UnexpectedDecoderEvent,
    }
    try std.testing.expectError(error.InvalidState, decoder.next());
}

test "decode celld byte-exact Go v0.5.2 two-page vector" {
    var fixture: [211]u8 = undefined;
    try load_fixture("fixtures/celld_v052_two_page_snapshot.ltx", &fixture);
    var source = ltx.SliceReader.init(&fixture);
    var page_workspace: [65_536]u8 = undefined;
    var compressed_workspace: [66_000]u8 = undefined;
    var index_workspace: [8]ltx.PageIndexEntry = undefined;
    var decoder = try ltx.Decoder.init(
        .v3,
        limits,
        source.reader(),
        &page_workspace,
        &compressed_workspace,
        &index_workspace,
    );

    switch (try decoder.next()) {
        .header => |header| {
            try std.testing.expectEqual(@as(u32, 1024), header.page_size);
            try std.testing.expectEqual(@as(u32, 2), header.commit);
            try std.testing.expectEqual(@as(i64, 1000), header.timestamp_ms);
        },
        else => return error.UnexpectedDecoderEvent,
    }
    switch (try decoder.next()) {
        .unverified_page => |page| {
            const expected: [1024]u8 = @splat(0x81);
            try std.testing.expectEqual(@as(u32, 1), page.header.page_number);
            try std.testing.expectEqualSlices(u8, &expected, page.data);
        },
        else => return error.UnexpectedDecoderEvent,
    }
    switch (try decoder.next()) {
        .unverified_page => |page| {
            var expected: [1024]u8 = undefined;
            for (&expected, 0..) |*byte, index| byte.* = "abcd"[index % 4];
            try std.testing.expectEqual(@as(u32, 2), page.header.page_number);
            try std.testing.expectEqualSlices(u8, &expected, page.data);
        },
        else => return error.UnexpectedDecoderEvent,
    }
    switch (try decoder.next()) {
        .page_block_complete => {},
        else => return error.UnexpectedDecoderEvent,
    }
    switch (try decoder.next()) {
        .verified => |verified| {
            try std.testing.expectEqual(@as(u32, 2), verified.page_count);
            try std.testing.expectEqual(@as(u64, fixture.len), verified.byte_count);
            try std.testing.expectEqual(
                @as(u64, 0xa096_39bc_718d_9c58),
                verified.trailer.post_apply_checksum.value,
            );
            try std.testing.expectEqual(
                @as(u64, 0xdc2f_8726_a386_540e),
                verified.trailer.file_checksum.value,
            );
        },
        else => return error.UnexpectedDecoderEvent,
    }
}

test "decode current Go incremental fixture" {
    var fixture: [206]u8 = undefined;
    try load_fixture("fixtures/go_v3_incremental.ltx", &fixture);
    var source = ltx.SliceReader.init(&fixture);
    var page_workspace: [65_536]u8 = undefined;
    var compressed_workspace: [66_000]u8 = undefined;
    var index_workspace: [8]ltx.PageIndexEntry = undefined;
    var decoder = try ltx.Decoder.init(
        .v3,
        limits,
        source.reader(),
        &page_workspace,
        &compressed_workspace,
        &index_workspace,
    );

    switch (try decoder.next()) {
        .header => |header| {
            try std.testing.expectEqual(@as(u32, 512), header.page_size);
            try std.testing.expectEqual(@as(u64, 2), header.min_txid.value);
            try std.testing.expectEqual(@as(u64, 4), header.max_txid.value);
            try std.testing.expectEqual(@as(i64, -1000), header.timestamp_ms);
            try std.testing.expectEqual(ltx.checksum_flag | 0x1234, header.pre_apply_checksum.value);
        },
        else => return error.UnexpectedDecoderEvent,
    }
    switch (try decoder.next()) {
        .unverified_page => |page| {
            const expected: [512]u8 = @splat(0x31);
            try std.testing.expectEqual(@as(u32, 1), page.header.page_number);
            try std.testing.expectEqualSlices(u8, &expected, page.data);
        },
        else => return error.UnexpectedDecoderEvent,
    }
    switch (try decoder.next()) {
        .unverified_page => |page| {
            const expected: [512]u8 = @splat(0x33);
            try std.testing.expectEqual(@as(u32, 3), page.header.page_number);
            try std.testing.expectEqualSlices(u8, &expected, page.data);
        },
        else => return error.UnexpectedDecoderEvent,
    }
    switch (try decoder.next()) {
        .page_block_complete => {},
        else => return error.UnexpectedDecoderEvent,
    }
    switch (try decoder.next()) {
        .verified => |verified| {
            try std.testing.expectEqual(@as(u32, 2), verified.page_count);
            try std.testing.expectEqual(@as(u64, fixture.len), verified.byte_count);
            try std.testing.expectEqual(
                ltx.checksum_flag | 0x5678,
                verified.trailer.post_apply_checksum.value,
            );
            try std.testing.expectEqual(
                @as(u64, 0xd1f8_ea54_6c26_2bd3),
                verified.trailer.file_checksum.value,
            );
        },
        else => return error.UnexpectedDecoderEvent,
    }
}

test "decode current Go no-checksum fixture" {
    var fixture: [182]u8 = undefined;
    try load_fixture("fixtures/go_v3_no_checksum.ltx", &fixture);
    var source = ltx.SliceReader.init(&fixture);
    var page_workspace: [65_536]u8 = undefined;
    var compressed_workspace: [66_000]u8 = undefined;
    var index_workspace: [8]ltx.PageIndexEntry = undefined;
    var decoder = try ltx.Decoder.init(
        .v3,
        limits,
        source.reader(),
        &page_workspace,
        &compressed_workspace,
        &index_workspace,
    );

    switch (try decoder.next()) {
        .header => |header| {
            try std.testing.expect(header.no_checksum());
            try std.testing.expectEqual(@as(u32, 4096), header.page_size);
            try std.testing.expectEqual(@as(u64, 5), header.min_txid.value);
        },
        else => return error.UnexpectedDecoderEvent,
    }
    switch (try decoder.next()) {
        .unverified_page => |page| {
            const expected: [4096]u8 = @splat(0xa5);
            try std.testing.expectEqual(@as(u32, 2), page.header.page_number);
            try std.testing.expectEqualSlices(u8, &expected, page.data);
        },
        else => return error.UnexpectedDecoderEvent,
    }
    _ = try decoder.next();
    switch (try decoder.next()) {
        .verified => |verified| {
            try std.testing.expectEqual(@as(u64, 0), verified.trailer.post_apply_checksum.value);
            try std.testing.expectEqual(
                @as(u64, 0xc231_c44d_d37c_4fc6),
                verified.trailer.file_checksum.value,
            );
        },
        else => return error.UnexpectedDecoderEvent,
    }
}

test "decode current Go maximum-page-size fixture around SQLite lock page" {
    var fixture: [722]u8 = undefined;
    try load_fixture("fixtures/go_v3_near_lock_page.ltx", &fixture);
    var source = ltx.SliceReader.init(&fixture);
    var page_workspace: [65_536]u8 = undefined;
    var compressed_workspace: [66_000]u8 = undefined;
    var index_workspace: [8]ltx.PageIndexEntry = undefined;
    var decoder = try ltx.Decoder.init(
        .v3,
        limits,
        source.reader(),
        &page_workspace,
        &compressed_workspace,
        &index_workspace,
    );

    switch (try decoder.next()) {
        .header => |header| {
            try std.testing.expectEqual(@as(u32, 65_536), header.page_size);
            try std.testing.expectEqual(@as(u32, 16_386), header.commit);
            try std.testing.expectEqual(@as(u32, 16_385), try ltx.lock_page_number(header.page_size));
        },
        else => return error.UnexpectedDecoderEvent,
    }
    switch (try decoder.next()) {
        .unverified_page => |page| {
            const expected: [65_536]u8 = @splat(0x84);
            try std.testing.expectEqual(@as(u32, 16_384), page.header.page_number);
            try std.testing.expectEqualSlices(u8, &expected, page.data);
        },
        else => return error.UnexpectedDecoderEvent,
    }
    switch (try decoder.next()) {
        .unverified_page => |page| {
            const expected: [65_536]u8 = @splat(0x86);
            try std.testing.expectEqual(@as(u32, 16_386), page.header.page_number);
            try std.testing.expectEqualSlices(u8, &expected, page.data);
        },
        else => return error.UnexpectedDecoderEvent,
    }
    _ = try decoder.next();
    switch (try decoder.next()) {
        .verified => |verified| {
            try std.testing.expectEqual(ltx.checksum_flag | 0x222, verified.trailer.post_apply_checksum.value);
            try std.testing.expectEqual(
                @as(u64, 0xe2f9_b769_66a7_55f5),
                verified.trailer.file_checksum.value,
            );
        },
        else => return error.UnexpectedDecoderEvent,
    }
}

test "decode Go v3 empty database checksum semantics" {
    var fixture: [131]u8 = undefined;
    try load_fixture("fixtures/go_v3_empty_snapshot.ltx", &fixture);
    var source = ltx.SliceReader.init(&fixture);
    var page_workspace: [65_536]u8 = undefined;
    var compressed_workspace: [66_000]u8 = undefined;
    var index_workspace: [8]ltx.PageIndexEntry = undefined;
    var decoder = try ltx.Decoder.init(
        .v3,
        limits,
        source.reader(),
        &page_workspace,
        &compressed_workspace,
        &index_workspace,
    );
    _ = try decoder.next();
    switch (try decoder.next()) {
        .page_block_complete => {},
        else => return error.UnexpectedDecoderEvent,
    }
    switch (try decoder.next()) {
        .verified => |verified| {
            try std.testing.expectEqual(@as(u32, 0), verified.page_count);
            try std.testing.expectEqual(ltx.checksum_flag, verified.trailer.post_apply_checksum.value);
            try std.testing.expectEqual(
                @as(u64, 0xef75_2d54_4ac8_c48f),
                verified.trailer.file_checksum.value,
            );
        },
        else => return error.UnexpectedDecoderEvent,
    }
}

test "Zig match-compressed output verifies through the Zig decoder" {
    var output: [2048]u8 = undefined;
    var sink = ltx.SliceWriter.init(&output);
    var compression_workspace: [66_000]u8 = undefined;
    var lz4_workspace: ltx.LZ4CompressionWorkspace = undefined;
    var encoder_index: [8]ltx.PageIndexEntry = undefined;
    var encoder = try ltx.Encoder.init(
        .v3,
        limits,
        sink.writer(),
        &compression_workspace,
        &lz4_workspace,
        &encoder_index,
    );
    const header = snapshot_header(1);
    try encoder.write_header(header);
    const page: [512]u8 = @splat(0);
    try encoder.write_page(1, &page);
    const post_apply_checksum = try ltx.checksum_page(1, &page);
    const encoded = try encoder.finish(post_apply_checksum);
    try std.testing.expectEqual(@as(u32, 1), encoded.page_count);
    try std.testing.expectEqual(@as(u64, sink.written().len), encoded.byte_count);
    try std.testing.expectEqual(@as(usize, 168), sink.written().len);
    try std.testing.expectEqual(
        @as(u64, 0xeb51_21d5_6d33_a656),
        encoded.trailer.file_checksum.value,
    );
    try std.testing.expectEqualSlices(
        u8,
        @embedFile("fixtures/go_v3_snapshot_zero_page.ltx"),
        sink.written(),
    );

    var source = ltx.SliceReader.init(sink.written());
    var page_workspace: [65_536]u8 = undefined;
    var decoder_compressed: [66_000]u8 = undefined;
    var decoder_index: [8]ltx.PageIndexEntry = undefined;
    var decoder = try ltx.Decoder.init(
        .v3,
        limits,
        source.reader(),
        &page_workspace,
        &decoder_compressed,
        &decoder_index,
    );
    _ = try decoder.next();
    switch (try decoder.next()) {
        .unverified_page => |decoded_page| {
            try std.testing.expectEqualSlices(u8, &page, decoded_page.data);
        },
        else => return error.UnexpectedDecoderEvent,
    }
    _ = try decoder.next();
    switch (try decoder.next()) {
        .verified => |verified| {
            try std.testing.expectEqual(encoded.trailer.file_checksum, verified.trailer.file_checksum);
            try std.testing.expectEqual(encoded.post_apply_position(), verified.post_apply_position());
        },
        else => return error.UnexpectedDecoderEvent,
    }
}

test "Zig encoder honors the configured literal-fallback cap" {
    var fallback_limits = limits;
    fallback_limits.max_page_size = 512;
    fallback_limits.max_compressed_page_size = 515;
    var output: [660]u8 = undefined;
    var sink = ltx.SliceWriter.init(&output);
    var compressed_workspace: [530]u8 = undefined;
    var lz4_workspace: ltx.LZ4CompressionWorkspace = undefined;
    var index_workspace: [8]ltx.PageIndexEntry = undefined;
    var encoder = try ltx.Encoder.init(
        .v3,
        fallback_limits,
        sink.writer(),
        &compressed_workspace,
        &lz4_workspace,
        &index_workspace,
    );
    try encoder.write_header(snapshot_header(1));
    const page: [512]u8 = @splat(0);
    try encoder.write_page(1, &page);
    const verified = try encoder.finish(try ltx.checksum_page(1, &page));

    try std.testing.expectEqual(@as(usize, 660), sink.written().len);
    try std.testing.expectEqual(@as(u32, 515), std.mem.readInt(
        u32,
        sink.written()[106..110],
        .big,
    ));
    try std.testing.expectEqual(
        @as(u64, 0xf9b8_95f2_3744_f218),
        verified.trailer.file_checksum.value,
    );
}

test "Zig encoder matches the Celld and Go v0.5.2 two-page file" {
    var output: [211]u8 = undefined;
    var sink = ltx.SliceWriter.init(&output);
    var compressed_workspace: [66_000]u8 = undefined;
    var lz4_workspace: ltx.LZ4CompressionWorkspace = undefined;
    var index_workspace: [8]ltx.PageIndexEntry = undefined;
    var encoder = try ltx.Encoder.init(
        .v3,
        limits,
        sink.writer(),
        &compressed_workspace,
        &lz4_workspace,
        &index_workspace,
    );
    var header = snapshot_header(2);
    header.page_size = 1024;
    header.timestamp_ms = 1000;
    try encoder.write_header(header);
    const page1: [1024]u8 = @splat(0x81);
    var page2: [1024]u8 = undefined;
    for (&page2, 0..) |*byte, index| byte.* = "abcd"[index % 4];
    try encoder.write_page(1, &page1);
    try encoder.write_page(2, &page2);
    const verified = try encoder.finish(.init(0xa096_39bc_718d_9c58));

    try std.testing.expectEqual(@as(u64, output.len), verified.byte_count);
    try std.testing.expectEqualSlices(
        u8,
        @embedFile("fixtures/celld_v052_two_page_snapshot.ltx"),
        sink.written(),
    );
}

test "decode historical Go legacy unflagged v3 fixture" {
    var fixture: [183]u8 = undefined;
    try load_fixture("fixtures/go_v3_legacy_unflagged.ltx", &fixture);
    var source = ltx.SliceReader.init(&fixture);
    var page_workspace: [65_536]u8 = undefined;
    var compressed_workspace: [66_000]u8 = undefined;
    var index_workspace: [8]ltx.PageIndexEntry = undefined;
    var decoder = try ltx.Decoder.init(
        .v3,
        limits,
        source.reader(),
        &page_workspace,
        &compressed_workspace,
        &index_workspace,
    );
    switch (try decoder.next()) {
        .header => |header| {
            try std.testing.expectEqual(@as(u32, 512), header.page_size);
            try std.testing.expectEqual(@as(u32, 1), header.commit);
        },
        else => return error.UnexpectedDecoderEvent,
    }
    switch (try decoder.next()) {
        .unverified_page => |page| {
            try std.testing.expectEqual(@as(u32, 1), page.header.page_number);
            try std.testing.expectEqual(@as(u16, 0), page.header.flags);
            try std.testing.expectEqualSlices(u8, &(@as([512]u8, @splat(0))), page.data);
        },
        else => return error.UnexpectedDecoderEvent,
    }
    switch (try decoder.next()) {
        .page_block_complete => {},
        else => return error.UnexpectedDecoderEvent,
    }
    switch (try decoder.next()) {
        .verified => |verified| {
            try std.testing.expectEqual(@as(u32, 1), verified.page_count);
            try std.testing.expectEqual(@as(u64, fixture.len), verified.byte_count);
            try std.testing.expectEqual(
                @as(u64, 0xefb1_f44f_ecd9_9000),
                verified.trailer.post_apply_checksum.value,
            );
            try std.testing.expectEqual(
                @as(u64, 0xae80_e106_9c9b_c795),
                verified.trailer.file_checksum.value,
            );
        },
        else => return error.UnexpectedDecoderEvent,
    }
    try std.testing.expectError(error.InvalidState, decoder.next());
}

test "decode historical Go mixed compressed and stored legacy pages" {
    var fixture: [725]u8 = undefined;
    try load_fixture("fixtures/go_v3_legacy_mixed.ltx", &fixture);
    var source = ltx.SliceReader.init(&fixture);
    var page_workspace: [65_536]u8 = undefined;
    var compressed_workspace: [66_000]u8 = undefined;
    var index_workspace: [8]ltx.PageIndexEntry = undefined;
    var decoder = try ltx.Decoder.init(
        .v3,
        limits,
        source.reader(),
        &page_workspace,
        &compressed_workspace,
        &index_workspace,
    );

    _ = try decoder.next();
    switch (try decoder.next()) {
        .unverified_page => |page| {
            try std.testing.expectEqual(@as(u32, 1), page.header.page_number);
            try std.testing.expectEqualSlices(u8, &(@as([512]u8, @splat(0))), page.data);
        },
        else => return error.UnexpectedDecoderEvent,
    }
    switch (try decoder.next()) {
        .unverified_page => |page| {
            var expected: [512]u8 = undefined;
            fill_xorshift_page(&expected);
            try std.testing.expectEqual(@as(u32, 2), page.header.page_number);
            try std.testing.expectEqual(@as(u16, 0), page.header.flags);
            try std.testing.expectEqualSlices(u8, &expected, page.data);
        },
        else => return error.UnexpectedDecoderEvent,
    }
    switch (try decoder.next()) {
        .page_block_complete => {},
        else => return error.UnexpectedDecoderEvent,
    }
    switch (try decoder.next()) {
        .verified => |verified| {
            try std.testing.expectEqual(@as(u32, 2), verified.page_count);
            try std.testing.expectEqual(@as(u64, fixture.len), verified.byte_count);
            try std.testing.expectEqual(
                @as(u64, 0xff27_3ef8_3077_8b70),
                verified.trailer.post_apply_checksum.value,
            );
            try std.testing.expectEqual(
                @as(u64, 0xc33c_5c9b_2434_d957),
                verified.trailer.file_checksum.value,
            );
        },
        else => return error.UnexpectedDecoderEvent,
    }
}

test "incremental positions require TXID and checksum continuity" {
    var output: [2048]u8 = undefined;
    var sink = ltx.SliceWriter.init(&output);
    var compressed_workspace: [66_000]u8 = undefined;
    var lz4_workspace: ltx.LZ4CompressionWorkspace = undefined;
    var index_workspace: [8]ltx.PageIndexEntry = undefined;
    var encoder = try ltx.Encoder.init(
        .v3,
        limits,
        sink.writer(),
        &compressed_workspace,
        &lz4_workspace,
        &index_workspace,
    );
    var header = snapshot_header(1);
    header.min_txid = .init(2);
    header.max_txid = .init(3);
    header.pre_apply_checksum = .init(ltx.checksum_flag | 0x1234);
    try encoder.write_header(header);
    const page: [512]u8 = @splat(0x5a);
    try encoder.write_page(1, &page);
    const post_apply_checksum = ltx.Checksum.init(ltx.checksum_flag | 0x5678);
    const verified = try encoder.finish(post_apply_checksum);
    try verified.check_contiguous(.{
        .txid = .init(1),
        .post_apply_checksum = header.pre_apply_checksum,
    });
    try std.testing.expectError(
        error.NonContiguousTransition,
        verified.check_contiguous(.{
            .txid = .init(0),
            .post_apply_checksum = header.pre_apply_checksum,
        }),
    );
    try std.testing.expectError(
        error.DivergentHistory,
        verified.check_contiguous(.{
            .txid = .init(1),
            .post_apply_checksum = .init(ltx.checksum_flag | 0x9999),
        }),
    );

    var source = ltx.SliceReader.init(sink.written());
    var page_workspace: [65_536]u8 = undefined;
    var decoder_compressed: [66_000]u8 = undefined;
    var decoder_index: [8]ltx.PageIndexEntry = undefined;
    var decoder = try ltx.Decoder.init(
        .v3,
        limits,
        source.reader(),
        &page_workspace,
        &decoder_compressed,
        &decoder_index,
    );
    _ = try decoder.next();
    _ = try decoder.next();
    _ = try decoder.next();
    switch (try decoder.next()) {
        .verified => |decoded| {
            try std.testing.expectEqual(
                try verified.pre_apply_position(),
                try decoded.pre_apply_position(),
            );
            try std.testing.expectEqual(
                verified.post_apply_position(),
                decoded.post_apply_position(),
            );
        },
        else => return error.UnexpectedDecoderEvent,
    }
}

test "no-checksum incrementals keep database checksums zero" {
    var output: [2048]u8 = undefined;
    var sink = ltx.SliceWriter.init(&output);
    var compressed_workspace: [66_000]u8 = undefined;
    var lz4_workspace: ltx.LZ4CompressionWorkspace = undefined;
    var encoder_index: [8]ltx.PageIndexEntry = undefined;
    var encoder = try ltx.Encoder.init(
        .v3,
        limits,
        sink.writer(),
        &compressed_workspace,
        &lz4_workspace,
        &encoder_index,
    );
    var header = snapshot_header(1);
    header.flags = ltx.header_flag_no_checksum;
    header.min_txid = .init(2);
    header.max_txid = .init(2);
    try encoder.write_header(header);
    const page: [512]u8 = @splat(0xa5);
    try encoder.write_page(1, &page);
    const encoded = try encoder.finish(.init(0));
    try std.testing.expectEqual(@as(u64, 0), encoded.trailer.post_apply_checksum.value);

    var source = ltx.SliceReader.init(sink.written());
    var page_workspace: [65_536]u8 = undefined;
    var decoder_compressed: [66_000]u8 = undefined;
    var decoder_index: [8]ltx.PageIndexEntry = undefined;
    var decoder = try ltx.Decoder.init(
        .v3,
        limits,
        source.reader(),
        &page_workspace,
        &decoder_compressed,
        &decoder_index,
    );
    _ = try decoder.next();
    _ = try decoder.next();
    _ = try decoder.next();
    switch (try decoder.next()) {
        .verified => |verified| {
            try std.testing.expectEqual(
                @as(u64, 0),
                (try verified.pre_apply_position()).post_apply_checksum.value,
            );
            try std.testing.expectEqual(
                @as(u64, 0),
                verified.post_apply_position().post_apply_checksum.value,
            );
        },
        else => return error.UnexpectedDecoderEvent,
    }
}

test "no-checksum empty snapshot has a coherent zero-checksum encoding" {
    var output: [512]u8 = undefined;
    var sink = ltx.SliceWriter.init(&output);
    var compressed_workspace: [66_000]u8 = undefined;
    var lz4_workspace: ltx.LZ4CompressionWorkspace = undefined;
    var index_workspace: [8]ltx.PageIndexEntry = undefined;
    var encoder = try ltx.Encoder.init(
        .v3,
        limits,
        sink.writer(),
        &compressed_workspace,
        &lz4_workspace,
        &index_workspace,
    );
    var header = snapshot_header(0);
    header.flags = ltx.header_flag_no_checksum;
    try encoder.write_header(header);
    const verified = try encoder.finish(.init(0));
    try std.testing.expectEqual(@as(u64, 0), verified.trailer.post_apply_checksum.value);
    try std.testing.expect(verified.trailer.file_checksum.has_valid_flag());
}

test "fixed-seed generated snapshots encode deterministically" {
    var pages: [4][512]u8 = undefined;
    var state: u32 = 0x6c74_7821;
    for (&pages) |*page| {
        for (page) |*byte| {
            state = state *% 1_664_525 +% 1_013_904_223;
            byte.* = @truncate(state >> 24);
        }
    }

    var first: [4096]u8 = undefined;
    var second: [4096]u8 = undefined;
    const first_length = try encode_generated_snapshot(&first, &pages);
    const second_length = try encode_generated_snapshot(&second, &pages);
    try std.testing.expectEqual(first_length, second_length);
    try std.testing.expectEqualSlices(u8, first[0..first_length], second[0..second_length]);
}

fn encode_generated_snapshot(output: []u8, pages: *const [4][512]u8) !usize {
    var sink = ltx.SliceWriter.init(output);
    var compressed_workspace: [66_000]u8 = undefined;
    var lz4_workspace: ltx.LZ4CompressionWorkspace = undefined;
    var index_workspace: [8]ltx.PageIndexEntry = undefined;
    var encoder = try ltx.Encoder.init(
        .v3,
        limits,
        sink.writer(),
        &compressed_workspace,
        &lz4_workspace,
        &index_workspace,
    );
    try encoder.write_header(snapshot_header(pages.len));
    var post_apply_checksum = ltx.rolling_checksum_initial();
    for (pages, 1..) |*page, page_number| {
        const page_number_u32: u32 = @intCast(page_number);
        try encoder.write_page(page_number_u32, page);
        post_apply_checksum = try ltx.rolling_checksum_add(
            post_apply_checksum,
            try ltx.checksum_page(page_number_u32, page),
        );
    }
    const verified = try encoder.finish(post_apply_checksum);
    try std.testing.expectEqual(@as(u32, pages.len), verified.page_count);
    return sink.written().len;
}

fn snapshot_header(commit: u32) ltx.Header {
    return .{
        .flags = 0,
        .page_size = 512,
        .commit = commit,
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
}

fn fill_xorshift_page(page: *[512]u8) void {
    var state: u32 = 0x9e37_79b9;
    for (page) |*byte| {
        state ^= state << 13;
        state ^= state >> 17;
        state ^= state << 5;
        byte.* = @truncate(state);
    }
}

fn load_fixture(comptime path: []const u8, destination: []u8) !void {
    const source = @embedFile(path);
    if (source.len != destination.len) return error.InvalidBinaryFixture;
    @memcpy(destination, source);
}
