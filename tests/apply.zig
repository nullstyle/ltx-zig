const std = @import("std");
const ltx = @import("ltx");

const database_capacity_bytes: usize = 8 * 4096;
const max_input_bytes: usize = 4096;
const max_page_bytes: usize = 4096;
const max_compressed_bytes: usize = 4200;
const max_pages: usize = 8;

const codec_limits = ltx.Limits{
    .max_input_bytes = max_input_bytes,
    .max_output_bytes = database_capacity_bytes,
    .max_pages = max_pages,
    .max_page_size = max_page_bytes,
    .max_compressed_page_size = max_compressed_bytes,
    .max_page_index_bytes = max_input_bytes,
    .max_page_index_entries = max_pages,
    .max_varint_bytes = 10,
    .max_transaction_span = 100,
};

const apply_limits = ltx.ApplyLimits{
    .max_database_pages = max_pages,
    .max_database_bytes = database_capacity_bytes,
};

const celld_fixture = @embedFile("fixtures/celld_v052_two_page_snapshot.ltx");
const empty_fixture = @embedFile("fixtures/go_v3_empty_snapshot.ltx");
const no_checksum_fixture = @embedFile("fixtures/go_v3_no_checksum.ltx");

const BackendFailure = enum {
    none,
    begin,
    stage_first,
    stage_second,
    read,
    publish,
    publish_indeterminate_before_commit,
    publish_indeterminate_after_commit,
};

const PublishRace = enum {
    none,
    txid,
    checksum,
    page_size,
};

const BackendCall = enum {
    begin,
    stage_page,
    read_page,
    publish,
    abort,
};

const MemoryBackend = struct {
    published: [database_capacity_bytes]u8 = @splat(0),
    staged: [database_capacity_bytes]u8 = @splat(0),
    published_length_bytes: usize = 0,
    staged_length_bytes: usize = 0,
    position: ltx.Position = zero_position,
    page_size: ?u32 = null,
    plan: ?ltx.ApplyPlan = null,
    active: bool = false,
    failure: BackendFailure = .none,
    publish_race: PublishRace = .none,
    corrupt_staging_before_read: bool = false,
    begin_count: u8 = 0,
    stage_count: u8 = 0,
    read_count: u8 = 0,
    publish_attempt_count: u8 = 0,
    publish_count: u8 = 0,
    abort_count: u8 = 0,
    call_count: u8 = 0,
    calls: [32]BackendCall = @splat(.begin),

    const zero_position = ltx.Position{
        .txid = .init(0),
        .post_apply_checksum = .init(0),
    };

    fn backend(self: *MemoryBackend) ltx.ApplyBackend {
        return .{
            .context = self,
            .begin_fn = begin,
            .stage_page_fn = stage_page,
            .read_page_fn = read_page,
            .publish_fn = publish,
            .abort_fn = abort,
            .backing_bytes = &self.staged,
        };
    }

    fn seed(
        self: *MemoryBackend,
        bytes: []const u8,
        position: ltx.Position,
        page_size: ?u32,
    ) !void {
        if (bytes.len > self.published.len) return error.TestDatabaseTooLarge;
        @memset(&self.published, 0);
        @memcpy(self.published[0..bytes.len], bytes);
        self.published_length_bytes = bytes.len;
        self.position = position;
        self.page_size = page_size;
    }

    fn record(self: *MemoryBackend, call: BackendCall) void {
        std.debug.assert(self.call_count < self.calls.len);
        self.calls[self.call_count] = call;
        self.call_count += 1;
    }

    fn begin(
        context: *anyopaque,
        plan: ltx.ApplyPlan,
    ) error{ApplyBeginFailure}!ltx.ApplyCurrent {
        const self: *MemoryBackend = @ptrCast(@alignCast(context));
        self.record(.begin);
        self.begin_count += 1;
        if (self.failure == .begin) return error.ApplyBeginFailure;
        if (self.active) return error.ApplyBeginFailure;
        const target_length = std.math.cast(usize, plan.final_database_size_bytes) orelse {
            return error.ApplyBeginFailure;
        };
        if (target_length > self.staged.len) return error.ApplyBeginFailure;

        @memset(self.staged[0..target_length], 0);
        if (!plan.header.is_snapshot()) {
            const clone_length = @min(target_length, self.published_length_bytes);
            @memcpy(self.staged[0..clone_length], self.published[0..clone_length]);
        }
        self.staged_length_bytes = target_length;
        self.plan = plan;
        self.active = true;
        return .{ .position = self.position, .page_size = self.page_size };
    }

    fn stage_page(
        context: *anyopaque,
        page: ltx.StagedPage,
    ) error{ApplyStageFailure}!void {
        const self: *MemoryBackend = @ptrCast(@alignCast(context));
        self.record(.stage_page);
        self.stage_count += 1;
        if (!self.active) return error.ApplyStageFailure;
        if (self.failure == .stage_first and self.stage_count == 1) {
            return error.ApplyStageFailure;
        }
        if (self.failure == .stage_second and self.stage_count == 2) {
            return error.ApplyStageFailure;
        }
        const offset = std.math.cast(usize, page.offset_bytes) orelse {
            return error.ApplyStageFailure;
        };
        const end = std.math.add(usize, offset, page.data.len) catch {
            return error.ApplyStageFailure;
        };
        if (end > self.staged_length_bytes) return error.ApplyStageFailure;
        @memcpy(self.staged[offset..end], page.data);
    }

    fn read_page(
        context: *anyopaque,
        page_number: u32,
        destination: []u8,
    ) error{ApplyReadFailure}!void {
        const self: *MemoryBackend = @ptrCast(@alignCast(context));
        self.record(.read_page);
        self.read_count += 1;
        if (!self.active or self.failure == .read) return error.ApplyReadFailure;
        const plan = self.plan orelse return error.ApplyReadFailure;
        if (self.corrupt_staging_before_read and self.read_count == 1 and
            self.staged_length_bytes != 0)
        {
            self.staged[0] ^= 1;
        }
        if (page_number == 0 or destination.len != plan.header.page_size) {
            return error.ApplyReadFailure;
        }
        const page_index = @as(u64, page_number - 1);
        const offset_u64 = std.math.mul(
            u64,
            page_index,
            @as(u64, plan.header.page_size),
        ) catch return error.ApplyReadFailure;
        const offset = std.math.cast(usize, offset_u64) orelse {
            return error.ApplyReadFailure;
        };
        const end = std.math.add(usize, offset, destination.len) catch {
            return error.ApplyReadFailure;
        };
        if (end > self.staged_length_bytes) return error.ApplyReadFailure;
        @memcpy(destination, self.staged[offset..end]);
    }

    fn publish(
        context: *anyopaque,
        expected_current: ltx.ApplyCurrent,
        verified: ltx.VerifiedLTX,
    ) error{
        ApplyPublishFailure,
        ApplyPublishIndeterminate,
        NonContiguousTransition,
        DivergentHistory,
        DatabasePageSizeMismatch,
    }!void {
        const self: *MemoryBackend = @ptrCast(@alignCast(context));
        self.record(.publish);
        self.publish_attempt_count += 1;
        if (!self.active or self.failure == .publish) return error.ApplyPublishFailure;
        if (self.failure == .publish_indeterminate_before_commit) {
            self.active = false;
            return error.ApplyPublishIndeterminate;
        }
        switch (self.publish_race) {
            .none => {},
            .txid => self.position.txid.value +%= 1,
            .checksum => self.position.post_apply_checksum.value +%= 1,
            .page_size => self.page_size = if (self.page_size == 512) 1024 else 512,
        }
        if (self.position.txid.value != expected_current.position.txid.value) {
            return error.NonContiguousTransition;
        }
        if (self.position.post_apply_checksum.value !=
            expected_current.position.post_apply_checksum.value)
        {
            return error.DivergentHistory;
        }
        if (self.page_size != expected_current.page_size) {
            return error.DatabasePageSizeMismatch;
        }
        @memcpy(
            self.published[0..self.staged_length_bytes],
            self.staged[0..self.staged_length_bytes],
        );
        self.published_length_bytes = self.staged_length_bytes;
        self.position = verified.post_apply_position();
        self.page_size = verified.header.page_size;
        self.publish_count += 1;
        self.active = false;
        if (self.failure == .publish_indeterminate_after_commit) {
            return error.ApplyPublishIndeterminate;
        }
    }

    fn abort(context: *anyopaque) void {
        const self: *MemoryBackend = @ptrCast(@alignCast(context));
        self.record(.abort);
        self.abort_count += 1;
        self.active = false;
    }
};

const ApplyHarness = struct {
    source: ltx.SliceReader = undefined,
    page_workspace: [max_page_bytes]u8 = undefined,
    compressed_workspace: [max_compressed_bytes]u8 = undefined,
    index_workspace: [max_pages]ltx.PageIndexEntry = undefined,
    applier: ltx.StagedApplier = undefined,

    fn init(
        self: *ApplyHarness,
        input: []const u8,
        backend: ltx.ApplyBackend,
        mode: ltx.ApplyMode,
        limits: ltx.ApplyLimits,
    ) !void {
        self.source = ltx.SliceReader.init(input);
        self.applier = try ltx.StagedApplier.init(
            .v3,
            codec_limits,
            limits,
            mode,
            self.source.reader(),
            backend,
            &self.page_workspace,
            &self.compressed_workspace,
            &self.index_workspace,
        );
    }
};

test "verified Celld snapshot replaces privately and publishes copied pages once" {
    var backend = MemoryBackend{};
    var old_database: [2048]u8 = @splat(0x5a);
    try backend.seed(&old_database, .{
        .txid = .init(77),
        .post_apply_checksum = .init(ltx.checksum_flag | 0x77),
    }, 512);
    var harness: ApplyHarness = undefined;
    try harness.init(celld_fixture, backend.backend(), .replace_snapshot, apply_limits);

    const verified = try harness.applier.apply();

    try std.testing.expectEqual(ltx.ApplyState.published, harness.applier.current_state());
    try std.testing.expectEqual(@as(u32, 2), verified.page_count);
    try std.testing.expectEqual(@as(usize, 2048), backend.published_length_bytes);
    try std.testing.expectEqualSlices(u8, &(@as([1024]u8, @splat(0x81))), backend.published[0..1024]);
    var expected_second: [1024]u8 = undefined;
    for (&expected_second, 0..) |*byte, index| byte.* = "abcd"[index % 4];
    try std.testing.expectEqualSlices(u8, &expected_second, backend.published[1024..2048]);
    try std.testing.expectEqualDeep(verified.post_apply_position(), backend.position);
    try std.testing.expectEqual(@as(?u32, 1024), backend.page_size);
    try expect_counts(&backend, 1, 2, 2, 1, 0);
    try expect_calls(&backend, &.{ .begin, .stage_page, .stage_page, .read_page, .read_page, .publish });

    const call_count = backend.call_count;
    try std.testing.expectError(error.InvalidState, harness.applier.apply());
    try std.testing.expectEqual(call_count, backend.call_count);
}

test "snapshot replacement policy is explicit and contiguous mode rejects history" {
    var backend = MemoryBackend{};
    const old_database: [2048]u8 = @splat(0x5a);
    const old_position = ltx.Position{
        .txid = .init(4),
        .post_apply_checksum = .init(ltx.checksum_flag | 0x44),
    };
    try backend.seed(&old_database, old_position, 512);
    var harness: ApplyHarness = undefined;
    try harness.init(celld_fixture, backend.backend(), .contiguous, apply_limits);

    try std.testing.expectError(error.NonContiguousTransition, harness.applier.apply());

    try expect_failed_without_publication(
        &harness.applier,
        &backend,
        &old_database,
        old_position,
        512,
    );
    try expect_counts(&backend, 1, 0, 0, 0, 1);
    try expect_calls(&backend, &.{ .begin, .abort });
}

test "coherent incremental preserves untouched pages and truncates only at publish" {
    var encoded: [2048]u8 = undefined;
    var initial_database: [4 * 512]u8 = undefined;
    const fixture_length = try encode_incremental(&encoded, &initial_database);
    const pre_checksum = try database_checksum(&initial_database, 512);

    var backend = MemoryBackend{};
    try backend.seed(&initial_database, .{
        .txid = .init(1),
        .post_apply_checksum = pre_checksum,
    }, 512);
    var harness: ApplyHarness = undefined;
    try harness.init(encoded[0..fixture_length], backend.backend(), .contiguous, apply_limits);

    const verified = try harness.applier.apply();

    var expected: [3 * 512]u8 = undefined;
    @memset(expected[0..512], 0x31);
    @memcpy(expected[512..1024], initial_database[512..1024]);
    @memset(expected[1024..1536], 0x33);
    try std.testing.expectEqualSlices(u8, &expected, backend.published[0..backend.published_length_bytes]);
    try std.testing.expectEqual(@as(usize, expected.len), backend.published_length_bytes);
    try std.testing.expectEqualDeep(verified.post_apply_position(), backend.position);
    try std.testing.expectEqual(@as(?u32, 512), backend.page_size);
    try expect_counts(&backend, 1, 2, 3, 1, 0);
    try expect_calls(&backend, &.{
        .begin,
        .stage_page,
        .stage_page,
        .read_page,
        .read_page,
        .read_page,
        .publish,
    });
}

test "incremental TXID and checksum divergence abort without publication" {
    var encoded: [2048]u8 = undefined;
    var initial_database: [4 * 512]u8 = undefined;
    const fixture_length = try encode_incremental(&encoded, &initial_database);
    const pre_checksum = try database_checksum(&initial_database, 512);

    const cases = [_]struct {
        position: ltx.Position,
        mode: ltx.ApplyMode,
        expected: ltx.Error,
    }{
        .{
            .position = .{ .txid = .init(9), .post_apply_checksum = pre_checksum },
            .mode = .contiguous,
            .expected = error.NonContiguousTransition,
        },
        .{
            .position = .{
                .txid = .init(1),
                .post_apply_checksum = .init(pre_checksum.value ^ 1),
            },
            .mode = .contiguous,
            .expected = error.DivergentHistory,
        },
        .{
            .position = .{ .txid = .init(9), .post_apply_checksum = pre_checksum },
            .mode = .replace_snapshot,
            .expected = error.NonContiguousTransition,
        },
    };
    for (cases) |case| {
        var backend = MemoryBackend{};
        try backend.seed(&initial_database, case.position, 512);
        var harness: ApplyHarness = undefined;
        try harness.init(encoded[0..fixture_length], backend.backend(), case.mode, apply_limits);

        try std.testing.expectError(case.expected, harness.applier.apply());

        try expect_failed_without_publication(
            &harness.applier,
            &backend,
            &initial_database,
            case.position,
            512,
        );
        try expect_counts(&backend, 1, 0, 0, 0, 1);
    }
}

test "no-checksum transitions ignore checksum but still require exact TXID" {
    var initial_database: [2 * 4096]u8 = @splat(0x11);
    const arbitrary_checksum = ltx.Checksum.init(0x1234_5678);
    var backend = MemoryBackend{};
    try backend.seed(&initial_database, .{
        .txid = .init(4),
        .post_apply_checksum = arbitrary_checksum,
    }, 4096);
    var harness: ApplyHarness = undefined;
    try harness.init(no_checksum_fixture, backend.backend(), .contiguous, apply_limits);

    const verified = try harness.applier.apply();

    try std.testing.expectEqual(@as(u64, 0), verified.trailer.post_apply_checksum.value);
    try std.testing.expectEqual(@as(u8, 0), backend.read_count);
    try std.testing.expectEqualSlices(u8, initial_database[0..4096], backend.published[0..4096]);
    try std.testing.expectEqualSlices(u8, &(@as([4096]u8, @splat(0xa5))), backend.published[4096..8192]);
    try std.testing.expectEqual(@as(?u32, 4096), backend.page_size);

    var wrong_backend = MemoryBackend{};
    const wrong_position = ltx.Position{
        .txid = .init(3),
        .post_apply_checksum = arbitrary_checksum,
    };
    try wrong_backend.seed(&initial_database, wrong_position, 4096);
    var wrong_harness: ApplyHarness = undefined;
    try wrong_harness.init(
        no_checksum_fixture,
        wrong_backend.backend(),
        .contiguous,
        apply_limits,
    );
    try std.testing.expectError(error.NonContiguousTransition, wrong_harness.applier.apply());
    try expect_failed_without_publication(
        &wrong_harness.applier,
        &wrong_backend,
        &initial_database,
        wrong_position,
        4096,
    );
}

test "no-checksum incremental still requires the authoritative page size" {
    const initial_database: [2 * 4096]u8 = @splat(0x29);
    const position = ltx.Position{
        .txid = .init(4),
        .post_apply_checksum = .init(0x1234_5678),
    };
    var backend = MemoryBackend{};
    try backend.seed(&initial_database, position, 1024);
    var harness: ApplyHarness = undefined;
    try harness.init(no_checksum_fixture, backend.backend(), .contiguous, apply_limits);

    try std.testing.expectError(error.DatabasePageSizeMismatch, harness.applier.apply());

    try expect_failed_without_publication(
        &harness.applier,
        &backend,
        &initial_database,
        position,
        1024,
    );
    try expect_counts(&backend, 1, 0, 0, 0, 1);
    try expect_calls(&backend, &.{ .begin, .abort });
}

test "terminal corruption and trailing bytes after pages never publish" {
    var corrupted: [celld_fixture.len]u8 = undefined;
    @memcpy(&corrupted, celld_fixture);
    corrupted[corrupted.len - 1] ^= 1;
    var trailing: [celld_fixture.len + 1]u8 = undefined;
    @memcpy(trailing[0..celld_fixture.len], celld_fixture);
    trailing[celld_fixture.len] = 0xa5;

    const cases = [_]struct { input: []const u8, expected: ltx.Error }{
        .{ .input = &corrupted, .expected = error.ChecksumMismatch },
        .{ .input = &trailing, .expected = error.TrailingBytes },
    };
    for (cases) |case| {
        var backend = MemoryBackend{};
        const original: [2048]u8 = @splat(0x7b);
        const position = ltx.Position{
            .txid = .init(19),
            .post_apply_checksum = .init(ltx.checksum_flag | 0x19),
        };
        try backend.seed(&original, position, 512);
        var harness: ApplyHarness = undefined;
        try harness.init(case.input, backend.backend(), .replace_snapshot, apply_limits);

        try std.testing.expectError(case.expected, harness.applier.apply());

        try expect_failed_without_publication(
            &harness.applier,
            &backend,
            &original,
            position,
            512,
        );
        try expect_counts(&backend, 1, 2, 0, 0, 1);
    }
}

test "empty snapshot publishes a zero-length database without page callbacks" {
    var backend = MemoryBackend{};
    const original: [1024]u8 = @splat(0x66);
    try backend.seed(&original, .{
        .txid = .init(6),
        .post_apply_checksum = .init(ltx.checksum_flag | 6),
    }, null);
    var harness: ApplyHarness = undefined;
    try harness.init(empty_fixture, backend.backend(), .replace_snapshot, apply_limits);

    const verified = try harness.applier.apply();

    try std.testing.expectEqual(@as(usize, 0), backend.published_length_bytes);
    try std.testing.expectEqual(ltx.checksum_flag, verified.trailer.post_apply_checksum.value);
    try std.testing.expectEqual(@as(?u32, 512), backend.page_size);
    try expect_counts(&backend, 1, 0, 0, 1, 0);
    try expect_calls(&backend, &.{ .begin, .publish });
}

test "backend failures abort exactly once after begin and never publish" {
    const cases = [_]BackendFailure{
        .begin,
        .stage_first,
        .stage_second,
        .read,
        .publish,
    };
    for (cases) |failure| {
        var backend = MemoryBackend{ .failure = failure };
        const original: [2048]u8 = @splat(0x37);
        const position = ltx.Position{
            .txid = .init(20),
            .post_apply_checksum = .init(ltx.checksum_flag | 0x20),
        };
        try backend.seed(&original, position, 512);
        var harness: ApplyHarness = undefined;
        try harness.init(celld_fixture, backend.backend(), .replace_snapshot, apply_limits);

        const expected: ltx.Error = switch (failure) {
            .begin => error.ApplyBeginFailure,
            .stage_first, .stage_second => error.ApplyStageFailure,
            .read => error.ApplyReadFailure,
            .publish => error.ApplyPublishFailure,
            .publish_indeterminate_before_commit,
            .publish_indeterminate_after_commit,
            => unreachable,
            .none => unreachable,
        };
        try std.testing.expectError(expected, harness.applier.apply());

        try expect_failed_without_publication(
            &harness.applier,
            &backend,
            &original,
            position,
            512,
        );
        const expected_abort: u8 = if (failure == .begin) 0 else 1;
        try std.testing.expectEqual(expected_abort, backend.abort_count);
        try std.testing.expectEqual(@as(u8, 0), backend.publish_count);
        if (failure == .publish) {
            try std.testing.expectEqual(@as(u8, 1), backend.publish_attempt_count);
        }
    }
}

test "indeterminate publication requires recovery for either commit outcome" {
    const cases = [_]struct {
        failure: BackendFailure,
        expected_publish_count: u8,
    }{
        .{ .failure = .publish_indeterminate_before_commit, .expected_publish_count = 0 },
        .{ .failure = .publish_indeterminate_after_commit, .expected_publish_count = 1 },
    };
    for (cases) |case| {
        var backend = MemoryBackend{ .failure = case.failure };
        const original: [2048]u8 = @splat(0x71);
        const position = ltx.Position{
            .txid = .init(23),
            .post_apply_checksum = .init(ltx.checksum_flag | 0x23),
        };
        try backend.seed(&original, position, 512);
        var harness: ApplyHarness = undefined;
        try harness.init(celld_fixture, backend.backend(), .replace_snapshot, apply_limits);

        try std.testing.expectError(error.ApplyPublishIndeterminate, harness.applier.apply());

        try std.testing.expectEqual(
            ltx.ApplyState.recovery_required,
            harness.applier.current_state(),
        );
        try std.testing.expectEqual(@as(u8, 1), backend.publish_attempt_count);
        try std.testing.expectEqual(case.expected_publish_count, backend.publish_count);
        try std.testing.expectEqual(@as(u8, 0), backend.abort_count);
        try std.testing.expect(!backend.active);
        try expect_calls(&backend, &.{
            .begin,
            .stage_page,
            .stage_page,
            .read_page,
            .read_page,
            .publish,
        });
        if (case.expected_publish_count == 0) {
            try std.testing.expectEqualDeep(position, backend.position);
            try std.testing.expectEqualSlices(
                u8,
                &original,
                backend.published[0..backend.published_length_bytes],
            );
        } else {
            try std.testing.expect(backend.position.txid.value != position.txid.value);
            try std.testing.expect(!std.mem.eql(
                u8,
                &original,
                backend.published[0..backend.published_length_bytes],
            ));
        }
        const call_count = backend.call_count;
        try std.testing.expectError(error.InvalidState, harness.applier.apply());
        try std.testing.expectEqual(call_count, backend.call_count);
    }
}

test "full staged-image checksum mismatch aborts without publication" {
    var backend = MemoryBackend{ .corrupt_staging_before_read = true };
    const original: [2048]u8 = @splat(0x48);
    const position = ltx.Position{
        .txid = .init(22),
        .post_apply_checksum = .init(ltx.checksum_flag | 0x22),
    };
    try backend.seed(&original, position, 512);
    var harness: ApplyHarness = undefined;
    try harness.init(celld_fixture, backend.backend(), .replace_snapshot, apply_limits);

    try std.testing.expectError(error.DatabaseChecksumMismatch, harness.applier.apply());

    try expect_failed_without_publication(
        &harness.applier,
        &backend,
        &original,
        position,
        512,
    );
    try expect_counts(&backend, 1, 2, 2, 0, 1);
    try expect_calls(&backend, &.{
        .begin,
        .stage_page,
        .stage_page,
        .read_page,
        .read_page,
        .abort,
    });
    try std.testing.expectEqual(@as(u8, 0), backend.publish_attempt_count);
}

test "database page and byte limits reject before begin and exact bounds succeed" {
    const limits_cases = [_]struct { limits: ltx.ApplyLimits, expected: ltx.Error }{
        .{
            .limits = .{ .max_database_pages = 1, .max_database_bytes = 2048 },
            .expected = error.DatabasePageLimitExceeded,
        },
        .{
            .limits = .{ .max_database_pages = 2, .max_database_bytes = 2047 },
            .expected = error.DatabaseSizeLimitExceeded,
        },
    };
    for (limits_cases) |case| {
        var backend = MemoryBackend{};
        var harness: ApplyHarness = undefined;
        try harness.init(celld_fixture, backend.backend(), .replace_snapshot, case.limits);
        try std.testing.expectError(case.expected, harness.applier.apply());
        try std.testing.expectEqual(@as(u8, 0), backend.begin_count);
        try std.testing.expectEqual(@as(u8, 0), backend.abort_count);
        try std.testing.expectEqual(ltx.ApplyState.failed, harness.applier.current_state());
    }

    var exact_backend = MemoryBackend{};
    var exact_harness: ApplyHarness = undefined;
    try exact_harness.init(
        celld_fixture,
        exact_backend.backend(),
        .replace_snapshot,
        .{ .max_database_pages = 2, .max_database_bytes = 2048 },
    );
    _ = try exact_harness.applier.apply();
    try std.testing.expectEqual(@as(u8, 1), exact_backend.publish_count);
}

test "initialization rejects backend storage aliasing decoder storage" {
    var input: [celld_fixture.len]u8 = undefined;
    @memcpy(&input, celld_fixture);
    var backend = MemoryBackend{};
    var source = ltx.SliceReader.init(&input);
    var page_workspace: [max_page_bytes]u8 = undefined;
    var compressed_workspace: [max_compressed_bytes]u8 = undefined;
    var index_workspace: [max_pages]ltx.PageIndexEntry = undefined;

    var alias_page = backend.backend();
    alias_page.backing_bytes = &page_workspace;
    try std.testing.expectError(error.WorkspaceAliasing, ltx.StagedApplier.init(
        .v3,
        codec_limits,
        apply_limits,
        .replace_snapshot,
        source.reader(),
        alias_page,
        &page_workspace,
        &compressed_workspace,
        &index_workspace,
    ));

    source = ltx.SliceReader.init(&input);
    var alias_input = backend.backend();
    alias_input.backing_bytes = &input;
    try std.testing.expectError(error.WorkspaceAliasing, ltx.StagedApplier.init(
        .v3,
        codec_limits,
        apply_limits,
        .replace_snapshot,
        source.reader(),
        alias_input,
        &page_workspace,
        &compressed_workspace,
        &index_workspace,
    ));
    try std.testing.expectEqual(@as(u8, 0), backend.begin_count);
}

test "atomic publish position race aborts the private image" {
    const races = [_]struct { race: PublishRace, expected: ltx.Error }{
        .{ .race = .txid, .expected = error.NonContiguousTransition },
        .{ .race = .checksum, .expected = error.DivergentHistory },
        .{ .race = .page_size, .expected = error.DatabasePageSizeMismatch },
    };
    for (races) |case| {
        var backend = MemoryBackend{ .publish_race = case.race };
        const original: [2048]u8 = @splat(0x92);
        try backend.seed(&original, MemoryBackend.zero_position, 512);
        var harness: ApplyHarness = undefined;
        try harness.init(celld_fixture, backend.backend(), .replace_snapshot, apply_limits);

        try std.testing.expectError(case.expected, harness.applier.apply());

        try std.testing.expectEqualSlices(
            u8,
            &original,
            backend.published[0..backend.published_length_bytes],
        );
        try expect_counts(&backend, 1, 2, 2, 0, 1);
        try std.testing.expectEqual(@as(u8, 1), backend.publish_attempt_count);
    }
}

const apply_seed_snapshot = indexed_slice_seed(1, celld_fixture);
const apply_seed_empty = indexed_slice_seed(2, empty_fixture);
const apply_seed_no_checksum = indexed_slice_seed(3, no_checksum_fixture);
const apply_corpus = [_][]const u8{
    &apply_seed_snapshot,
    &apply_seed_empty,
    &apply_seed_no_checksum,
};

test "staged apply fuzz never publishes before verification" {
    try std.testing.fuzz({}, fuzz_apply, .{ .corpus = &apply_corpus });
}

fn fuzz_apply(_: void, smith: *std.testing.Smith) !void {
    var input_storage: [1024]u8 = undefined;
    const input_length: usize = smith.slice(&input_storage);
    var backend = MemoryBackend{};
    seed_fuzz_position(&backend, input_storage[0..input_length]);
    var harness: ApplyHarness = undefined;
    try harness.init(
        input_storage[0..input_length],
        backend.backend(),
        .replace_snapshot,
        apply_limits,
    );

    const result = harness.applier.apply();
    if (result) |verified| {
        try std.testing.expectEqual(ltx.ApplyState.published, harness.applier.current_state());
        try std.testing.expectEqual(@as(u8, 1), backend.publish_count);
        try std.testing.expectEqual(@as(u8, 0), backend.abort_count);
        try std.testing.expectEqual(@as(u32, backend.stage_count), verified.page_count);
        try std.testing.expect(!backend.active);
    } else |_| {
        try std.testing.expectEqual(ltx.ApplyState.failed, harness.applier.current_state());
        try std.testing.expectEqual(@as(u8, 0), backend.publish_count);
        const expected_abort: u8 = if (backend.begin_count == 0) 0 else 1;
        try std.testing.expectEqual(expected_abort, backend.abort_count);
        try std.testing.expect(!backend.active);
    }
    const call_count = backend.call_count;
    try std.testing.expectError(error.InvalidState, harness.applier.apply());
    try std.testing.expectEqual(call_count, backend.call_count);
}

fn seed_fuzz_position(backend: *MemoryBackend, input: []const u8) void {
    if (input.len < 48 or !std.mem.eql(u8, input[0..4], "LTX1")) return;
    const min_txid = std.mem.readInt(u64, input[16..24], .big);
    if (min_txid == 0) return;
    const page_size = std.mem.readInt(u32, input[8..12], .big);
    if (page_size >= 512 and page_size <= 65_536 and std.math.isPowerOfTwo(page_size)) {
        backend.page_size = page_size;
    }
    backend.position = .{
        .txid = .init(min_txid - 1),
        .post_apply_checksum = .init(std.mem.readInt(u64, input[40..48], .big)),
    };
}

fn expect_counts(
    backend: *const MemoryBackend,
    begin_count: u8,
    stage_count: u8,
    read_count: u8,
    publish_count: u8,
    abort_count: u8,
) !void {
    try std.testing.expectEqual(begin_count, backend.begin_count);
    try std.testing.expectEqual(stage_count, backend.stage_count);
    try std.testing.expectEqual(read_count, backend.read_count);
    try std.testing.expectEqual(publish_count, backend.publish_count);
    try std.testing.expectEqual(abort_count, backend.abort_count);
    try std.testing.expect(!backend.active);
}

fn expect_calls(backend: *const MemoryBackend, expected: []const BackendCall) !void {
    try std.testing.expectEqualSlices(BackendCall, expected, backend.calls[0..backend.call_count]);
}

fn expect_failed_without_publication(
    applier: *ltx.StagedApplier,
    backend: *MemoryBackend,
    original: []const u8,
    position: ltx.Position,
    page_size: ?u32,
) !void {
    try std.testing.expectEqual(ltx.ApplyState.failed, applier.current_state());
    try std.testing.expectEqual(@as(u8, 0), backend.publish_count);
    try std.testing.expectEqual(original.len, backend.published_length_bytes);
    try std.testing.expectEqualSlices(
        u8,
        original,
        backend.published[0..backend.published_length_bytes],
    );
    try std.testing.expectEqualDeep(position, backend.position);
    try std.testing.expectEqual(page_size, backend.page_size);
    try std.testing.expect(!backend.active);
    const call_count = backend.call_count;
    const abort_count = backend.abort_count;
    try std.testing.expectError(error.InvalidState, applier.apply());
    try std.testing.expectEqual(call_count, backend.call_count);
    try std.testing.expectEqual(abort_count, backend.abort_count);
}

fn database_checksum(database: []const u8, page_size: usize) !ltx.Checksum {
    if (page_size == 0 or database.len % page_size != 0) return error.InvalidTestDatabase;
    var rolling = ltx.rolling_checksum_initial();
    var offset: usize = 0;
    var page_number: u32 = 1;
    while (offset < database.len) : (page_number += 1) {
        rolling = try ltx.rolling_checksum_add(
            rolling,
            try ltx.checksum_page(page_number, database[offset..][0..page_size]),
        );
        offset += page_size;
    }
    return rolling;
}

fn encode_incremental(output: *[2048]u8, initial_database: *[4 * 512]u8) !usize {
    for (0..4) |page_index| {
        const start = page_index * 512;
        @memset(initial_database[start..][0..512], @as(u8, @intCast((page_index + 1) * 0x11)));
    }
    const pre_checksum = try database_checksum(initial_database, 512);
    var expected_database: [3 * 512]u8 = undefined;
    @memset(expected_database[0..512], 0x31);
    @memcpy(expected_database[512..1024], initial_database[512..1024]);
    @memset(expected_database[1024..1536], 0x33);
    const post_checksum = try database_checksum(&expected_database, 512);

    var sink = ltx.SliceWriter.init(output);
    var compressed_workspace: [max_compressed_bytes]u8 = undefined;
    var compression_workspace: ltx.LZ4CompressionWorkspace = undefined;
    var index_workspace: [max_pages]ltx.PageIndexEntry = undefined;
    var encoder = try ltx.Encoder.init(
        .v3,
        codec_limits,
        sink.writer(),
        &compressed_workspace,
        &compression_workspace,
        &index_workspace,
    );
    try encoder.write_header(.{
        .flags = 0,
        .page_size = 512,
        .commit = 3,
        .min_txid = .init(2),
        .max_txid = .init(4),
        .timestamp_ms = -1000,
        .pre_apply_checksum = pre_checksum,
        .wal_offset = 0,
        .wal_size = 0,
        .wal_salt_1 = 0,
        .wal_salt_2 = 0,
        .node_id = 0,
    });
    try encoder.write_page(1, expected_database[0..512]);
    try encoder.write_page(3, expected_database[1024..1536]);
    _ = try encoder.finish(post_checksum);
    return sink.written().len;
}

fn indexed_slice_seed(
    comptime selector: u64,
    comptime bytes: []const u8,
) [12 + bytes.len]u8 {
    var seed: [12 + bytes.len]u8 = undefined;
    std.mem.writeInt(u64, seed[0..8], selector, .little);
    std.mem.writeInt(u32, seed[8..12], bytes.len, .little);
    @memcpy(seed[12..], bytes);
    return seed;
}
