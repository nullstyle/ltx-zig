//! Pinned WAL fixtures and their known answers, an independent structural
//! reference for the committed page map, deterministic mutations, and the
//! bounded fuzz entry point for `ltx_wal`.
//!
//! The `go_*` fixtures and every asserted frame fact are ported from
//! Litestream v0.5.11 `wal_reader_test.go` via the pinned Celld crate.
//! `celld_sample.wal` is the immutable Celld golden WAL captured by SQLite
//! 3.51.0; see `fixtures/wal/README.md` for provenance and hashes.

const std = @import("std");
const wal = @import("ltx_wal");

const go_ok = @embedFile("fixtures/wal/go_ok.wal");
const go_salt_mismatch = @embedFile("fixtures/wal/go_salt_mismatch.wal");
const go_frame_checksum_mismatch =
    @embedFile("fixtures/wal/go_frame_checksum_mismatch.wal");
const go_frame_salts = @embedFile("fixtures/wal/go_frame_salts.wal");
const celld_sample = @embedFile("fixtures/wal/celld_sample.wal");

const fixture_page_size: u32 = 4096;
const frame_size: u64 = wal.frame_header_size_bytes + fixture_page_size;

const fixture_limits = wal.Limits{
    .max_page_size = 65_536,
    .max_pages = 64,
    .max_frames = 256,
};

const TestWorkspaces = struct {
    slots: [fixture_limits.max_pages]wal.PageSlot =
        [_]wal.PageSlot{.{}} ** fixture_limits.max_pages,
    pending: [fixture_limits.max_pages]u32 =
        [_]u32{0} ** fixture_limits.max_pages,
    seen: [(fixture_limits.max_pages + 7) / 8]u8 =
        [_]u8{0} ** ((fixture_limits.max_pages + 7) / 8),
    entries: [fixture_limits.max_pages]wal.PageMapEntry =
        [_]wal.PageMapEntry{.{ .page_number = 0, .frame_offset_bytes = 0 }} **
        fixture_limits.max_pages,

    fn workspace(self: *TestWorkspaces) wal.PageMapWorkspace {
        return .{
            .slots = &self.slots,
            .pending_pages = &self.pending,
            .pending_seen = &self.seen,
            .entries = &self.entries,
        };
    }
};

test "go ok fixture frames verify with exact offsets and page bytes" {
    try std.testing.expectEqual(@as(usize, 12_392), go_ok.len);
    try std.testing.expectEqual(
        @as(u64, wal.header_size_bytes) + 3 * frame_size,
        @as(u64, go_ok.len),
    );

    var reader = try wal.Reader.init(fixture_limits, go_ok);
    try std.testing.expectEqual(fixture_page_size, reader.page_size_bytes());

    const first = try reader.read_frame();
    try std.testing.expectEqual(@as(u32, 1), first.page_number);
    try std.testing.expectEqual(@as(u32, 0), first.commit_pages);
    try std.testing.expectEqual(@as(u64, wal.header_size_bytes), first.offset_bytes);
    try std.testing.expectEqualSlices(u8, go_ok[56..4152], first.data);

    const second = try reader.read_frame();
    try std.testing.expectEqual(@as(u32, 2), second.page_number);
    try std.testing.expectEqual(@as(u32, 2), second.commit_pages);
    try std.testing.expectEqual(
        @as(u64, wal.header_size_bytes) + frame_size,
        second.offset_bytes,
    );
    try std.testing.expectEqualSlices(u8, go_ok[4176..8272], second.data);

    const third = try reader.read_frame();
    try std.testing.expectEqual(@as(u32, 2), third.page_number);
    try std.testing.expectEqual(@as(u32, 2), third.commit_pages);
    try std.testing.expectEqual(
        @as(u64, wal.header_size_bytes) + 2 * frame_size,
        third.offset_bytes,
    );
    try std.testing.expectEqualSlices(u8, go_ok[8296..12392], third.data);

    try std.testing.expectError(error.WalEnd, reader.read_frame());
    try std.testing.expectEqual(wal.Stop.end_of_input, reader.stop_reason().?);
}

test "go ok fixture page map pins the committed newest-page offsets" {
    var reader = try wal.Reader.init(fixture_limits, go_ok);
    var workspaces = TestWorkspaces{};
    const map = try reader.page_map(workspaces.workspace());
    try std.testing.expectEqual(@as(u64, 3), map.frame_count);
    try std.testing.expectEqual(@as(u32, 2), map.commit_pages);
    try std.testing.expectEqual(@as(usize, 2), map.pages.len);
    try std.testing.expectEqual(@as(u32, 1), map.pages[0].page_number);
    try std.testing.expectEqual(
        @as(u64, wal.header_size_bytes),
        map.pages[0].frame_offset_bytes,
    );
    try std.testing.expectEqual(@as(u32, 2), map.pages[1].page_number);
    try std.testing.expectEqual(
        @as(u64, wal.header_size_bytes) + 2 * frame_size,
        map.pages[1].frame_offset_bytes,
    );
    try std.testing.expectEqual(@as(u64, go_ok.len), map.end_offset_bytes);
    try std.testing.expectEqual(wal.Stop.end_of_input, map.stop);
}

test "salt and checksum mismatch fixtures stop after the first frame" {
    var salted = try wal.Reader.init(fixture_limits, go_salt_mismatch);
    const salted_first = try salted.read_frame();
    try std.testing.expectEqual(@as(u32, 1), salted_first.page_number);
    try std.testing.expectError(error.SaltMismatch, salted.read_frame());
    const mismatched = salted.stop_reason().?;
    try std.testing.expectEqual(
        std.mem.readInt(u32, go_salt_mismatch[4160..4164], .big),
        mismatched.salt_mismatch.salt_1,
    );

    var corrupted = try wal.Reader.init(fixture_limits, go_frame_checksum_mismatch);
    const corrupted_first = try corrupted.read_frame();
    try std.testing.expectEqual(@as(u32, 1), corrupted_first.page_number);
    try std.testing.expectError(error.FrameChecksumMismatch, corrupted.read_frame());
    try std.testing.expectEqual(wal.Stop.checksum_mismatch, corrupted.stop_reason().?);
}

test "malformed headers report each pinned cause" {
    try std.testing.expectError(error.TruncatedHeader, wal.Reader.init(fixture_limits, &.{}));
    try std.testing.expectError(
        error.TruncatedHeader,
        wal.Reader.init(fixture_limits, go_ok[0..10]),
    );
    try std.testing.expectError(
        error.InvalidMagic,
        wal.Reader.init(fixture_limits, &[_]u8{0} ** 32),
    );
    const bad_checksum = [32]u8{
        0x37, 0x7f, 0x06, 0x83, 0x00, 0x00, 0x00, 0x00, //
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, //
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, //
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    };
    try std.testing.expectError(
        error.HeaderChecksumMismatch,
        wal.Reader.init(fixture_limits, &bad_checksum),
    );
    const bad_version = [32]u8{
        0x37, 0x7f, 0x06, 0x83, 0x00, 0x00, 0x00, 0x01, //
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, //
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, //
        0x15, 0x7b, 0x20, 0x92, 0xbb, 0xf8, 0x34, 0x1d,
    };
    try std.testing.expectError(
        error.UnsupportedVersion,
        wal.Reader.init(fixture_limits, &bad_version),
    );

    const page_limited = wal.Limits{
        .max_page_size = 1024,
        .max_pages = 64,
        .max_frames = 256,
    };
    try std.testing.expectError(
        error.PageSizeLimitExceeded,
        wal.Reader.init(page_limited, go_ok),
    );
}

test "partial frames at each truncation point stop as torn" {
    const offsets = [_]usize{ 40, 56, 1000 };
    for (offsets) |offset| {
        var reader = try wal.Reader.init(fixture_limits, go_ok[0..offset]);
        try std.testing.expectError(error.TruncatedFrame, reader.read_frame());
        try std.testing.expectEqual(wal.Stop.truncated_frame, reader.stop_reason().?);
    }
}

test "offset resume replays the second frame and rejects bad offsets" {
    const salt = wal.SaltPair{
        .salt_1 = std.mem.readInt(u32, go_ok[16..20], .big),
        .salt_2 = std.mem.readInt(u32, go_ok[20..24], .big),
    };
    const resume_offset: u64 = wal.header_size_bytes + frame_size;

    var reader = try wal.Reader.init_with_offset(
        fixture_limits,
        go_ok,
        resume_offset,
        salt,
    );
    const frame = try reader.read_frame();
    try std.testing.expectEqual(@as(u32, 2), frame.page_number);
    try std.testing.expectEqual(@as(u32, 2), frame.commit_pages);
    try std.testing.expectEqualSlices(u8, go_ok[4176..8272], frame.data);
    // The third frame still verifies through the seeded chain.
    const tail = try reader.read_frame();
    try std.testing.expectEqual(@as(u32, 2), tail.page_number);
    try std.testing.expectEqualSlices(u8, go_ok[8296..12392], tail.data);
    try std.testing.expectError(error.WalEnd, reader.read_frame());

    try std.testing.expectError(
        error.InvalidOffset,
        wal.Reader.init_with_offset(fixture_limits, go_ok, wal.header_size_bytes, salt),
    );
    try std.testing.expectError(
        error.InvalidOffset,
        wal.Reader.init_with_offset(fixture_limits, go_ok, resume_offset + 7, salt),
    );
    try std.testing.expectError(
        error.PreviousFrameMismatch,
        wal.Reader.init_with_offset(
            fixture_limits,
            go_ok,
            resume_offset,
            .{ .salt_1 = 0xdead_beef, .salt_2 = 0xfeed_face },
        ),
    );
}

test "frame census collects the pinned distinct salt pairs" {
    try std.testing.expectEqual(
        @as(u64, wal.header_size_bytes) + 10 * frame_size,
        @as(u64, go_frame_salts.len),
    );
    var reader = try wal.Reader.init(fixture_limits, go_frame_salts);

    var out: [4]wal.SaltPair = undefined;
    const all = try reader.frame_salts_until(
        .{ .salt_1 = 0x0000_0000, .salt_2 = 0x0000_0000 },
        &out,
    );
    try std.testing.expectEqual(@as(usize, 3), all.len);
    const expected = [_]wal.SaltPair{
        .{ .salt_1 = 0x1b9a_294b, .salt_2 = 0x37f9_1916 },
        .{ .salt_1 = 0x1b9a_294a, .salt_2 = 0x031f_195e },
        .{ .salt_1 = 0x1b9a_2949, .salt_2 = 0x13b3_dd67 },
    };
    for (expected) |pair| {
        var found = false;
        for (all) |collected| {
            if (std.meta.eql(collected, pair)) found = true;
        }
        try std.testing.expect(found);
    }

    var one: [4]wal.SaltPair = undefined;
    const stopped = try reader.frame_salts_until(all[0], &one);
    try std.testing.expectEqual(@as(usize, 1), stopped.len);
    try std.testing.expect(std.meta.eql(stopped[0], all[0]));
}

test "celld golden sample verifies every frame and matches the reference map" {
    try std.testing.expectEqual(@as(usize, 16_512), celld_sample.len);
    var reader = try wal.Reader.init(fixture_limits, celld_sample);
    try std.testing.expectEqual(fixture_page_size, reader.page_size_bytes());
    const header = reader.header();
    try std.testing.expectEqual(@as(u32, 0x9bf2_9a02), header.salt_1);
    try std.testing.expectEqual(@as(u32, 0x6867_0130), header.salt_2);

    var frame_count: u64 = 0;
    while (true) {
        const frame = reader.read_frame() catch |err| switch (err) {
            error.WalEnd => break,
            else => return err,
        };
        try std.testing.expect(frame.page_number >= 1);
        frame_count += 1;
    }
    try std.testing.expectEqual(
        @as(u64, wal.header_size_bytes) + frame_count * frame_size,
        @as(u64, celld_sample.len),
    );

    try check_reference_map(celld_sample);
    try check_reference_map(go_ok);
}

const RefPage = struct {
    present: bool = false,
    committed_offset: u64 = 0,
    pending_offset: u64 = 0,
    pending: bool = false,
};

// An independent structural reference for `page_map`: frame headers are read
// directly, checksums are ignored, and Celld's map semantics (per-transaction
// staging, commit promotion, newest-page precedence, final-commit filtering)
// are simulated with plain arrays. Valid fixtures must produce identical
// committed maps in both implementations.
fn check_reference_map(bytes: []const u8) !void {
    const page_size = std.mem.readInt(u32, bytes[8..12], .big);
    const step: u64 = wal.frame_header_size_bytes + page_size;

    var pages: [fixture_limits.max_pages]RefPage =
        [_]RefPage{.{}} ** fixture_limits.max_pages;
    var commit_pages: u32 = 0;
    var end_offset_bytes: u64 = 0;

    var offset: u64 = wal.header_size_bytes;
    while (offset + step <= bytes.len) : (offset += step) {
        const frame_offset: usize = @intCast(offset);
        const page_number = std.mem.readInt(u32, bytes[frame_offset..][0..4], .big);
        const commit = std.mem.readInt(u32, bytes[frame_offset + 4 ..][0..4], .big);
        const slot = &pages[page_number - 1];
        slot.present = true;
        slot.pending = true;
        slot.pending_offset = offset;
        if (commit != 0) {
            for (&pages) |*candidate| {
                if (!candidate.pending) continue;
                candidate.committed_offset = candidate.pending_offset;
                candidate.pending = false;
                const frame_end = candidate.committed_offset + step;
                if (frame_end > end_offset_bytes) end_offset_bytes = frame_end;
            }
            commit_pages = commit;
        }
    }

    var expected: [fixture_limits.max_pages]wal.PageMapEntry = undefined;
    var expected_count: usize = 0;
    var number: u32 = 1;
    while (number <= commit_pages and number <= pages.len) : (number += 1) {
        const slot = pages[number - 1];
        if (!slot.present or slot.pending) continue;
        if (slot.committed_offset == 0) continue;
        expected[expected_count] = .{
            .page_number = number,
            .frame_offset_bytes = slot.committed_offset,
        };
        expected_count += 1;
    }
    if (expected_count == 0) {
        commit_pages = 0;
        end_offset_bytes = 0;
    }

    var reader = try wal.Reader.init(fixture_limits, bytes);
    var workspaces = TestWorkspaces{};
    const map = try reader.page_map(workspaces.workspace());
    try std.testing.expectEqual(@as(usize, expected_count), map.pages.len);
    try std.testing.expectEqual(commit_pages, map.commit_pages);
    try std.testing.expectEqual(end_offset_bytes, map.end_offset_bytes);
    for (expected[0..expected_count], map.pages) |reference, actual| {
        try std.testing.expectEqual(reference.page_number, actual.page_number);
        try std.testing.expectEqual(
            reference.frame_offset_bytes,
            actual.frame_offset_bytes,
        );
    }
}

test "deterministic mutations never panic and preserve map invariants" {
    // Truncation at every offset of the Go fixture and a stride of the larger
    // Celld sample.
    try mutate_truncations(go_ok, 1);
    try mutate_truncations(celld_sample, 97);

    // Single-bit flips inside page data must break the cumulative checksum at
    // exactly that frame.
    var mutable: [16_512]u8 = undefined;
    @memcpy(mutable[0..go_ok.len], go_ok);
    var index: usize = 56;
    while (index < 4152) : (index += 1) {
        mutable[index] ^= 0x01;
        var reader = wal.Reader.init(fixture_limits, mutable[0..go_ok.len]) catch unreachable;
        try std.testing.expectError(error.FrameChecksumMismatch, reader.read_frame());
        mutable[index] ^= 0x01;
    }
    @memcpy(mutable[0..go_ok.len], go_ok);
    index = 4176;
    while (index < 8272) : (index += 1) {
        mutable[index] ^= 0x01;
        var reader = wal.Reader.init(fixture_limits, mutable[0..go_ok.len]) catch unreachable;
        _ = try reader.read_frame();
        try std.testing.expectError(error.FrameChecksumMismatch, reader.read_frame());
        mutable[index] ^= 0x01;
    }

    // Header bit flips: the magic region reports invalid magic, except the
    // one bit that swaps the two valid magics, which then fails the checksum
    // under the other byte order; every other header byte is covered by the
    // stored header checksum.
    @memcpy(mutable[0..go_ok.len], go_ok);
    var byte_index: usize = 0;
    while (byte_index < wal.header_size_bytes) : (byte_index += 1) {
        var bit: u3 = 0;
        while (true) : (bit += 1) {
            mutable[byte_index] ^= @as(u8, 1) << bit;
            const result = wal.Reader.init(fixture_limits, mutable[0..go_ok.len]);
            if (byte_index < 4) {
                if (result) |_| {
                    return error.TestUnexpectedResult;
                } else |err| switch (err) {
                    error.InvalidMagic, error.HeaderChecksumMismatch => {},
                    else => return err,
                }
            } else {
                try std.testing.expectError(error.HeaderChecksumMismatch, result);
            }
            mutable[byte_index] ^= @as(u8, 1) << bit;
            if (bit == 7) break;
        }
    }

    // Zero runs break structural verification without panic.
    @memcpy(&mutable, celld_sample);
    var run_offset: usize = 0;
    while (run_offset < mutable.len) : (run_offset += 512) {
        @memset(mutable[run_offset..][0..64], 0);
        try exercise_parser(mutable[0..celld_sample.len]);
        @memcpy(&mutable, celld_sample);
    }
}

fn mutate_truncations(bytes: []const u8, stride: usize) !void {
    var length: usize = 0;
    while (length <= bytes.len) : (length += stride) {
        try exercise_parser(bytes[0..length]);
    }
}

/// Runs every parser entry point and checks structural invariants on success.
/// Used directly by the mutation suite and by the fuzz entry point.
fn exercise_parser(bytes: []const u8) !void {
    var reader = wal.Reader.init(fixture_limits, bytes) catch return;

    var frame_count: u64 = 0;
    while (frame_count < fixture_limits.max_frames) : (frame_count += 1) {
        _ = reader.read_frame() catch break;
    }
    if (reader.stop_reason()) |stop| {
        switch (stop) {
            .end_of_input, .truncated_frame, .salt_mismatch, .checksum_mismatch => {},
        }
    }

    var fresh = wal.Reader.init(fixture_limits, bytes) catch return;
    var workspaces = TestWorkspaces{};
    const map = fresh.page_map(workspaces.workspace()) catch return;
    try expect_map_invariants(bytes, map);
}

fn expect_map_invariants(bytes: []const u8, map: wal.PageMap) !void {
    if (map.pages.len == 0) {
        try std.testing.expectEqual(@as(u32, 0), map.commit_pages);
        try std.testing.expectEqual(@as(u64, 0), map.end_offset_bytes);
    } else {
        try std.testing.expect(map.commit_pages != 0);
        try std.testing.expect(map.end_offset_bytes != 0);
        try std.testing.expect(
            map.pages[map.pages.len - 1].page_number <= map.commit_pages,
        );
    }
    var previous: u32 = 0;
    for (map.pages) |entry| {
        try std.testing.expect(entry.page_number > previous);
        previous = entry.page_number;
        try std.testing.expect(entry.frame_offset_bytes >= wal.header_size_bytes);
        try std.testing.expect(entry.frame_offset_bytes < bytes.len);
    }
    try std.testing.expect(map.end_offset_bytes <= bytes.len);
    try std.testing.expect(map.frame_count <= fixture_limits.max_frames);
}

const wal_corpus = [_][]const u8{ go_ok, celld_sample };

test "wal parser fuzz corpus is structurally invariant" {
    try std.testing.fuzz({}, fuzz_wal, .{ .corpus = &wal_corpus });
}

fn fuzz_wal(_: void, smith: *std.testing.Smith) !void {
    var storage: [16_512]u8 = undefined;
    const input_length: usize = smith.slice(&storage);
    try exercise_parser(storage[0..input_length]);
}
