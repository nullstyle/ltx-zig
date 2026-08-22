const std = @import("std");
const ltx = @import("ltx");

pub const small_page_size_bytes: usize = 4096;
pub const large_page_size_bytes: usize = 65_536;
pub const max_page_size_bytes: usize = large_page_size_bytes;
pub const max_pages: usize = 4;
pub const max_inputs: usize = 16;

const codec_case_count: usize = 6;
const snapshot_page_count: usize = 4;
const compact_initial_page_count: usize = 4;
const compact_total_page_count: usize = 19;
const compact_case_count: usize = 3;
const max_file_bytes: usize = 80 * 1024;
const max_compressed_bytes: usize = 65_809;
const apply_database_capacity_bytes: usize = snapshot_page_count * small_page_size_bytes;
const compact_input_counts = [compact_case_count]usize{ 1, 4, 16 };
const compact_decoded_page_counts = [compact_case_count]u64{ 4, 7, 19 };
const compact_commits = [compact_case_count]usize{ 4, 3, 3 };

pub const codec_limits = ltx.Limits{
    .max_input_bytes = max_file_bytes,
    .max_output_bytes = max_file_bytes,
    .max_pages = max_pages,
    .max_page_size = max_page_size_bytes,
    .max_compressed_page_size = max_compressed_bytes,
    .max_page_index_bytes = 256,
    .max_page_index_entries = max_pages,
    .max_varint_bytes = 10,
    .max_transaction_span = 32,
};

pub const compaction_limits = ltx.CompactionLimits{
    .max_inputs = max_inputs,
    .max_total_pages = 32,
};

pub const apply_limits = ltx.ApplyLimits{
    .max_database_pages = snapshot_page_count,
    .max_database_bytes = apply_database_capacity_bytes,
};

pub const Workload = enum {
    encode_4k_zero,
    encode_4k_mixed,
    encode_4k_random,
    encode_64k_zero,
    encode_64k_mixed,
    encode_64k_random,
    decode_4k_zero,
    decode_4k_mixed,
    decode_4k_random,
    decode_64k_zero,
    decode_64k_mixed,
    decode_64k_random,
    compact_1,
    compact_4,
    compact_16,
    apply_checked,
    apply_no_checksum,

    pub fn name(self: Workload) []const u8 {
        return switch (self) {
            .encode_4k_zero => "encode-4k-zero",
            .encode_4k_mixed => "encode-4k-mixed",
            .encode_4k_random => "encode-4k-random",
            .encode_64k_zero => "encode-64k-zero",
            .encode_64k_mixed => "encode-64k-mixed",
            .encode_64k_random => "encode-64k-random",
            .decode_4k_zero => "decode-4k-zero",
            .decode_4k_mixed => "decode-4k-mixed",
            .decode_4k_random => "decode-4k-random",
            .decode_64k_zero => "decode-64k-zero",
            .decode_64k_mixed => "decode-64k-mixed",
            .decode_64k_random => "decode-64k-random",
            .compact_1 => "compact-1-input",
            .compact_4 => "compact-4-input",
            .compact_16 => "compact-16-input",
            .apply_checked => "apply-checked",
            .apply_no_checksum => "apply-no-checksum",
        };
    }

    pub fn is_encode(self: Workload) bool {
        return switch (self) {
            .encode_4k_zero,
            .encode_4k_mixed,
            .encode_4k_random,
            .encode_64k_zero,
            .encode_64k_mixed,
            .encode_64k_random,
            => true,
            else => false,
        };
    }

    pub fn is_decode(self: Workload) bool {
        return switch (self) {
            .decode_4k_zero,
            .decode_4k_mixed,
            .decode_4k_random,
            .decode_64k_zero,
            .decode_64k_mixed,
            .decode_64k_random,
            => true,
            else => false,
        };
    }

    pub fn is_compact(self: Workload) bool {
        return switch (self) {
            .compact_1, .compact_4, .compact_16 => true,
            else => false,
        };
    }

    pub fn is_apply(self: Workload) bool {
        return self == .apply_checked or self == .apply_no_checksum;
    }

    pub fn decoder_count(self: Workload) u32 {
        return if (self.is_compact()) @intCast(compact_input_count(self)) else 1;
    }
};

pub const Metrics = struct {
    logical_bytes: u64,
    wire_bytes: u64,
    result_wire_bytes: u64,
    /// Logical input pages used as the `ns/page` denominator.
    work_pages: u64,
    decoded_events: u64,
    decoded_pages: u64,
    emitted_pages: u64,
    stage_callbacks: u64,
    read_callbacks: u64,
    publish_callbacks: u64,
};

pub const Outcome = struct {
    verified: ltx.VerifiedLTX,
    result_wire_bytes: u64,
    decoded_events: u64 = 0,
    decoded_pages: u64 = 0,
    emitted_pages: u64 = 0,
    stage_callbacks: u64 = 0,
    read_callbacks: u64 = 0,
    publish_callbacks: u64 = 0,
    fingerprint: u64,
};

const Pattern = enum { zero, mixed, random };

const CodecSpec = struct {
    page_size_bytes: usize,
    pattern: Pattern,
    seed: u32,
};

const codec_specs = [codec_case_count]CodecSpec{
    .{ .page_size_bytes = small_page_size_bytes, .pattern = .zero, .seed = 1 },
    .{ .page_size_bytes = small_page_size_bytes, .pattern = .mixed, .seed = 2 },
    .{ .page_size_bytes = small_page_size_bytes, .pattern = .random, .seed = 3 },
    .{ .page_size_bytes = large_page_size_bytes, .pattern = .zero, .seed = 4 },
    .{ .page_size_bytes = large_page_size_bytes, .pattern = .mixed, .seed = 5 },
    .{ .page_size_bytes = large_page_size_bytes, .pattern = .random, .seed = 6 },
};

const PageSpec = struct {
    page_number: u32,
    data: []const u8,
};

const EncodedFile = struct {
    bytes: [max_file_bytes]u8 = undefined,
    length_bytes: usize = 0,
    digest: u64 = 0,
    verified: ltx.VerifiedLTX = undefined,

    fn slice(self: *const EncodedFile) []const u8 {
        return self.bytes[0..self.length_bytes];
    }
};

const EncodeWorkspace = struct {
    output: [max_file_bytes]u8 = undefined,
    compressed: [max_compressed_bytes]u8 = undefined,
    compression: ltx.LZ4CompressionWorkspace = undefined,
    index: [max_pages]ltx.PageIndexEntry = undefined,
    length_bytes: usize = 0,

    fn execute(
        self: *EncodeWorkspace,
        header: ltx.Header,
        pages: []const PageSpec,
        post_checksum: ltx.Checksum,
    ) !Outcome {
        if (pages.len == 0 or pages.len > max_pages) return error.InvalidEncodeFixture;
        var sink = ltx.SliceWriter.init(&self.output);
        var encoder = try ltx.Encoder.init(
            .v3,
            codec_limits,
            sink.writer(),
            &self.compressed,
            &self.compression,
            &self.index,
        );
        try encoder.write_header(header);
        for (pages) |page| try encoder.write_page(page.page_number, page.data);
        const verified = try encoder.finish(post_checksum);
        self.length_bytes = sink.written().len;
        return make_outcome(verified, self.slice(), verified.page_count);
    }

    fn slice(self: *const EncodeWorkspace) []const u8 {
        return self.output[0..self.length_bytes];
    }
};

const DecodeWorkspace = struct {
    source: ltx.SliceReader = undefined,
    page: [max_page_size_bytes]u8 = undefined,
    compressed: [max_compressed_bytes]u8 = undefined,
    index: [max_pages]ltx.PageIndexEntry = undefined,

    fn execute(self: *DecodeWorkspace, bytes: []const u8) !Outcome {
        var decoder = try make_decoder(self, bytes);
        var event_count: u64 = 0;
        var page_count: u64 = 0;
        var fingerprint: u64 = 0;
        for (0..decoder.event_budget()) |_| {
            const event = try decoder.next();
            event_count += 1;
            switch (event) {
                .header, .page_block_complete => {},
                .unverified_page => |page| {
                    page_count += 1;
                    fingerprint = page_observation(fingerprint, page);
                },
                .verified => |verified| return .{
                    .verified = verified,
                    .result_wire_bytes = verified.byte_count,
                    .decoded_events = event_count,
                    .decoded_pages = page_count,
                    .emitted_pages = page_count,
                    .fingerprint = fingerprint ^ verified.trailer.file_checksum.value,
                },
            }
        }
        return error.DecoderDidNotTerminate;
    }
};

const InputWorkspace = struct {
    source: ltx.SliceReader = undefined,
    page: [max_page_size_bytes]u8 = undefined,
    compressed: [max_compressed_bytes]u8 = undefined,
    index: [max_pages]ltx.PageIndexEntry = undefined,

    fn input(self: *InputWorkspace, bytes: []const u8) ltx.CompactionInput {
        self.source = ltx.SliceReader.init(bytes);
        return ltx.CompactionInput.init(
            self.source.reader(),
            &self.page,
            &self.compressed,
            &self.index,
        );
    }
};

const CompactWorkspace = struct {
    input_workspaces: [max_inputs]InputWorkspace = undefined,
    inputs: [max_inputs]ltx.CompactionInput = undefined,
    output: [max_file_bytes]u8 = undefined,
    compressed: [max_compressed_bytes]u8 = undefined,
    compression: ltx.LZ4CompressionWorkspace = undefined,
    index: [max_pages]ltx.PageIndexEntry = undefined,
    length_bytes: usize = 0,

    fn execute(self: *CompactWorkspace, files: []const EncodedFile) !Outcome {
        if (files.len == 0 or files.len > max_inputs) return error.InvalidCompactionFixture;
        for (files, 0..) |*file, index| {
            self.inputs[index] = self.input_workspaces[index].input(file.slice());
        }
        var sink = ltx.SliceWriter.init(&self.output);
        var compactor = try ltx.Compactor.init(
            .v3,
            codec_limits,
            compaction_limits,
            self.inputs[0..files.len],
            sink.writer(),
            &self.compressed,
            &self.compression,
            &self.index,
        );
        const verified = try compactor.compact();
        self.length_bytes = sink.written().len;
        var outcome = make_outcome(verified, self.slice(), verified.page_count);
        try add_compact_input_counts(files, &outcome);
        return outcome;
    }

    fn slice(self: *const CompactWorkspace) []const u8 {
        return self.output[0..self.length_bytes];
    }
};

fn add_compact_input_counts(files: []const EncodedFile, outcome: *Outcome) !void {
    var decoded_pages: u64 = 0;
    for (files) |file| {
        decoded_pages = try std.math.add(u64, decoded_pages, file.verified.page_count);
    }
    const structural_events = try std.math.mul(u64, files.len, 3);
    outcome.decoded_pages = decoded_pages;
    outcome.decoded_events = try std.math.add(u64, decoded_pages, structural_events);
}

const MemoryBackend = struct {
    published: [apply_database_capacity_bytes]u8 = undefined,
    staged: [apply_database_capacity_bytes]u8 = undefined,
    published_length_bytes: usize = 0,
    staged_length_bytes: usize = 0,
    position: ltx.Position = zero_position,
    page_size: ?u32 = null,
    plan: ?ltx.ApplyPlan = null,
    active: bool = false,
    stage_count: u32 = 0,
    read_count: u32 = 0,
    publish_count: u32 = 0,

    const zero_position = ltx.Position{
        .txid = .init(0),
        .post_apply_checksum = .init(0),
    };

    fn reset(self: *MemoryBackend) void {
        self.published_length_bytes = 0;
        self.staged_length_bytes = 0;
        self.position = zero_position;
        self.page_size = null;
        self.plan = null;
        self.active = false;
        self.stage_count = 0;
        self.read_count = 0;
        self.publish_count = 0;
    }

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

    fn begin(context: *anyopaque, plan: ltx.ApplyPlan) error{ApplyBeginFailure}!ltx.ApplyCurrent {
        const self: *MemoryBackend = @ptrCast(@alignCast(context));
        if (self.active) return error.ApplyBeginFailure;
        const length = std.math.cast(usize, plan.final_database_size_bytes) orelse
            return error.ApplyBeginFailure;
        if (length > self.staged.len) return error.ApplyBeginFailure;
        @memset(self.staged[0..length], 0);
        if (!plan.header.is_snapshot()) {
            const copied = @min(length, self.published_length_bytes);
            @memcpy(self.staged[0..copied], self.published[0..copied]);
        }
        self.staged_length_bytes = length;
        self.plan = plan;
        self.active = true;
        return .{ .position = self.position, .page_size = self.page_size };
    }

    fn stage_page(context: *anyopaque, page: ltx.StagedPage) error{ApplyStageFailure}!void {
        const self: *MemoryBackend = @ptrCast(@alignCast(context));
        if (!self.active or page.page_number == 0) return error.ApplyStageFailure;
        const plan = self.plan orelse return error.ApplyStageFailure;
        if (page.data.len != plan.header.page_size) return error.ApplyStageFailure;
        const expected = std.math.mul(u64, page.page_number - 1, plan.header.page_size) catch
            return error.ApplyStageFailure;
        if (page.offset_bytes != expected) return error.ApplyStageFailure;
        const offset = std.math.cast(usize, page.offset_bytes) orelse
            return error.ApplyStageFailure;
        const end = std.math.add(usize, offset, page.data.len) catch
            return error.ApplyStageFailure;
        if (end > self.staged_length_bytes) return error.ApplyStageFailure;
        @memcpy(self.staged[offset..end], page.data);
        self.stage_count = std.math.add(u32, self.stage_count, 1) catch
            return error.ApplyStageFailure;
    }

    fn read_page(
        context: *anyopaque,
        page_number: u32,
        destination: []u8,
    ) error{ApplyReadFailure}!void {
        const self: *MemoryBackend = @ptrCast(@alignCast(context));
        const plan = self.plan orelse return error.ApplyReadFailure;
        if (!self.active or page_number == 0 or destination.len != plan.header.page_size) {
            return error.ApplyReadFailure;
        }
        const offset_u64 = std.math.mul(u64, page_number - 1, plan.header.page_size) catch
            return error.ApplyReadFailure;
        const offset = std.math.cast(usize, offset_u64) orelse return error.ApplyReadFailure;
        const end = std.math.add(usize, offset, destination.len) catch
            return error.ApplyReadFailure;
        if (end > self.staged_length_bytes) return error.ApplyReadFailure;
        @memcpy(destination, self.staged[offset..end]);
        self.read_count = std.math.add(u32, self.read_count, 1) catch
            return error.ApplyReadFailure;
    }

    fn publish(
        context: *anyopaque,
        expected: ltx.ApplyCurrent,
        verified: ltx.VerifiedLTX,
    ) error{
        ApplyPublishFailure,
        ApplyPublishIndeterminate,
        NonContiguousTransition,
        DivergentHistory,
        DatabasePageSizeMismatch,
    }!void {
        const self: *MemoryBackend = @ptrCast(@alignCast(context));
        if (!self.active) return error.ApplyPublishFailure;
        if (expected.position.txid.value != self.position.txid.value) {
            return error.NonContiguousTransition;
        }
        if (expected.position.post_apply_checksum.value !=
            self.position.post_apply_checksum.value)
        {
            return error.DivergentHistory;
        }
        if (expected.page_size != self.page_size) return error.DatabasePageSizeMismatch;
        @memcpy(
            self.published[0..self.staged_length_bytes],
            self.staged[0..self.staged_length_bytes],
        );
        self.published_length_bytes = self.staged_length_bytes;
        self.position = verified.post_apply_position();
        self.page_size = verified.header.page_size;
        self.plan = null;
        self.active = false;
        self.publish_count += 1;
    }

    fn abort(context: *anyopaque) void {
        const self: *MemoryBackend = @ptrCast(@alignCast(context));
        self.staged_length_bytes = 0;
        self.plan = null;
        self.active = false;
    }
};

const ApplyWorkspace = struct {
    source: ltx.SliceReader = undefined,
    page: [max_page_size_bytes]u8 = undefined,
    compressed: [max_compressed_bytes]u8 = undefined,
    index: [max_pages]ltx.PageIndexEntry = undefined,
    backend_state: MemoryBackend = .{},

    fn execute(self: *ApplyWorkspace, encoded: []const u8) !Outcome {
        self.backend_state.reset();
        self.source = ltx.SliceReader.init(encoded);
        var applier = try ltx.StagedApplier.init(
            .v3,
            codec_limits,
            apply_limits,
            .replace_snapshot,
            self.source.reader(),
            self.backend_state.backend(),
            &self.page,
            &self.compressed,
            &self.index,
        );
        const verified = try applier.apply();
        const published = self.backend_state.published[0..self.backend_state.published_length_bytes];
        return .{
            .verified = verified,
            .result_wire_bytes = verified.byte_count,
            .decoded_events = @as(u64, verified.page_count) + 3,
            .decoded_pages = verified.page_count,
            .emitted_pages = verified.page_count,
            .stage_callbacks = self.backend_state.stage_count,
            .read_callbacks = self.backend_state.read_count,
            .publish_callbacks = self.backend_state.publish_count,
            .fingerprint = observe_bytes(published) ^ verified.trailer.file_checksum.value,
        };
    }
};

const CodecFixture = struct {
    page: [max_page_size_bytes]u8 = undefined,
    page_size_bytes: usize = 0,
    header: ltx.Header = undefined,
    checksum: ltx.Checksum = undefined,
    page_digest: u64 = 0,
    encoded: EncodedFile = .{},

    fn prepare(self: *CodecFixture, spec: CodecSpec, workspace: *EncodeWorkspace) !void {
        @memset(&self.page, 0);
        self.page_size_bytes = spec.page_size_bytes;
        fill_pattern(self.page_slice_mutable(), spec.pattern, spec.seed);
        const pages = [_]PageSpec{.{ .page_number = 1, .data = self.page_slice() }};
        self.checksum = try checksum_pages(&pages);
        self.header = make_header(0, spec.page_size_bytes, 1, 1, .init(0));
        const outcome = try workspace.execute(self.header, &pages, self.checksum);
        copy_encoded(&self.encoded, workspace, outcome.verified);
        self.page_digest = digest_bytes(self.page_slice());
    }

    fn page_slice(self: *const CodecFixture) []const u8 {
        return self.page[0..self.page_size_bytes];
    }

    fn page_slice_mutable(self: *CodecFixture) []u8 {
        return self.page[0..self.page_size_bytes];
    }
};

const SnapshotFixture = struct {
    pages: [snapshot_page_count][small_page_size_bytes]u8 = undefined,
    checked: EncodedFile = .{},
    no_checksum: EncodedFile = .{},
    checksum: ltx.Checksum = undefined,
    image_digest: u64 = 0,

    fn prepare(self: *SnapshotFixture, workspace: *EncodeWorkspace) !void {
        fill_snapshot_pages(&self.pages);
        const pages = page_specs_four(&self.pages);
        self.checksum = try checksum_pages(&pages);
        const header = make_header(0, small_page_size_bytes, snapshot_page_count, 1, .init(0));
        const checked = try workspace.execute(header, &pages, self.checksum);
        copy_encoded(&self.checked, workspace, checked.verified);

        var no_checksum_header = header;
        no_checksum_header.flags = ltx.header_flag_no_checksum;
        const unchecked = try workspace.execute(no_checksum_header, &pages, .init(0));
        copy_encoded(&self.no_checksum, workspace, unchecked.verified);
        self.image_digest = digest_bytes(std.mem.asBytes(&self.pages));
    }
};

const CompactFixture = struct {
    files: [max_inputs]EncodedFile = @splat(.{}),
    payloads: [compact_total_page_count][small_page_size_bytes]u8 = undefined,
    expected_images: [compact_case_count][compact_initial_page_count][small_page_size_bytes]u8 = undefined,
    expected_checksums: [compact_case_count]ltx.Checksum = undefined,
    expected_digests: [compact_case_count]u64 = undefined,
    expected_outputs: [compact_case_count]EncodedFile = @splat(.{}),

    fn prepare(
        self: *CompactFixture,
        encode_workspace: *EncodeWorkspace,
        compact_workspace: *CompactWorkspace,
    ) !void {
        // Prefixes 1, 4, and 16 form the benchmark topologies. Input four
        // shrinks commit four to three; later inputs update that smaller image.
        var database: [compact_initial_page_count][small_page_size_bytes]u8 = undefined;
        try self.prepare_snapshot(encode_workspace, &database);
        var previous_checksum = self.expected_checksums[0];
        var input_index: usize = 1;
        while (input_index < max_inputs) : (input_index += 1) {
            const commit: usize = if (input_index >= 3) 3 else 4;
            const page_number: u32 = if (input_index < 4)
                @intCast(input_index)
            else
                @intCast(input_index % 3 + 1);
            const payload_index = compact_initial_page_count + input_index - 1;
            fill_compact_page(&self.payloads[payload_index], input_index, page_number);
            database[page_number - 1] = self.payloads[payload_index];
            const checksum = try checksum_contiguous(database[0..commit]);
            const pages = [_]PageSpec{.{
                .page_number = page_number,
                .data = &self.payloads[payload_index],
            }};
            try encode_fixture_file(
                &self.files[input_index],
                encode_workspace,
                make_compact_header(commit, input_index + 1, previous_checksum),
                &pages,
                checksum,
            );
            previous_checksum = checksum;
            if (input_index == 3) self.capture_expected(1, &database, checksum);
            if (input_index == max_inputs - 1) self.capture_expected(2, &database, checksum);
        }
        try self.prepare_expected_outputs(compact_workspace);
    }

    fn prepare_snapshot(
        self: *CompactFixture,
        encode_workspace: *EncodeWorkspace,
        database: *[compact_initial_page_count][small_page_size_bytes]u8,
    ) !void {
        for (0..compact_initial_page_count) |index| {
            const page_number: u32 = @intCast(index + 1);
            fill_compact_page(&self.payloads[index], 0, page_number);
            database[index] = self.payloads[index];
        }
        const pages = page_specs_four(database);
        const checksum = try checksum_pages(&pages);
        try encode_fixture_file(
            &self.files[0],
            encode_workspace,
            make_compact_header(4, 1, .init(0)),
            &pages,
            checksum,
        );
        self.capture_expected(0, database, checksum);
    }

    fn capture_expected(
        self: *CompactFixture,
        case_index: usize,
        database: *const [compact_initial_page_count][small_page_size_bytes]u8,
        checksum: ltx.Checksum,
    ) void {
        @memset(std.mem.asBytes(&self.expected_images[case_index]), 0);
        const commit = compact_commits[case_index];
        for (0..commit) |page_index| {
            self.expected_images[case_index][page_index] = database[page_index];
        }
        self.expected_checksums[case_index] = checksum;
        const image = self.expected_images[case_index][0..commit];
        self.expected_digests[case_index] = digest_bytes(std.mem.sliceAsBytes(image));
    }

    fn prepare_expected_outputs(
        self: *CompactFixture,
        compact_workspace: *CompactWorkspace,
    ) !void {
        for (compact_input_counts, 0..) |input_count, case_index| {
            const outcome = try compact_workspace.execute(self.files[0..input_count]);
            copy_compacted(&self.expected_outputs[case_index], compact_workspace, outcome.verified);
        }
    }
};

pub const Harness = struct {
    codec_fixtures: [codec_case_count]CodecFixture = @splat(.{}),
    snapshot: SnapshotFixture = .{},
    compact_fixture: CompactFixture = .{},
    encode_workspace: EncodeWorkspace = .{},
    decode_workspace: DecodeWorkspace = .{},
    compact_workspace: CompactWorkspace = .{},
    apply_workspace: ApplyWorkspace = .{},

    pub fn init(self: *Harness) !void {
        self.* = .{};
        for (codec_specs, 0..) |spec, index| {
            try self.codec_fixtures[index].prepare(spec, &self.encode_workspace);
            try verify_codec_file(&self.decode_workspace, &self.codec_fixtures[index]);
        }
        try self.snapshot.prepare(&self.encode_workspace);
        try verify_snapshot_file(&self.decode_workspace, &self.snapshot, false);
        try verify_snapshot_file(&self.decode_workspace, &self.snapshot, true);
        try self.compact_fixture.prepare(&self.encode_workspace, &self.compact_workspace);
        for (0..compact_case_count) |case_index| {
            const expected = self.compact_fixture.expected_outputs[case_index].slice();
            try verify_compacted_bytes(self, case_index, expected);
        }
        try self.verify(.apply_checked, try self.run(.apply_checked));
        try self.verify(.apply_no_checksum, try self.run(.apply_no_checksum));
    }

    pub fn run(self: *Harness, comptime workload: Workload) !Outcome {
        if (workload.is_encode()) return self.run_encode(codec_index(workload));
        if (workload.is_decode()) {
            return self.decode_workspace.execute(
                self.codec_fixtures[codec_index(workload)].encoded.slice(),
            );
        }
        if (workload.is_compact()) {
            const count = compact_input_count(workload);
            return self.compact_workspace.execute(self.compact_fixture.files[0..count]);
        }
        return switch (workload) {
            .apply_checked => self.apply_workspace.execute(self.snapshot.checked.slice()),
            .apply_no_checksum => self.apply_workspace.execute(self.snapshot.no_checksum.slice()),
            else => unreachable,
        };
    }

    fn run_encode(self: *Harness, fixture_index: usize) !Outcome {
        const fixture = &self.codec_fixtures[fixture_index];
        const pages = [_]PageSpec{.{ .page_number = 1, .data = fixture.page_slice() }};
        return self.encode_workspace.execute(fixture.header, &pages, fixture.checksum);
    }

    pub fn verify(self: *Harness, comptime workload: Workload, outcome: Outcome) !void {
        if (workload.is_encode()) {
            try verify_encode(self, codec_index(workload), outcome);
        } else if (workload.is_decode()) {
            try verify_decode(self, codec_index(workload), outcome);
        } else if (workload.is_compact()) {
            try verify_compact_run(self, compact_case_index(workload), outcome);
        } else switch (workload) {
            .apply_checked => try verify_apply(self, outcome, false),
            .apply_no_checksum => try verify_apply(self, outcome, true),
            else => unreachable,
        }
        try require_equal_metrics(try self.metrics(workload), outcome);
    }

    pub fn metrics(self: *const Harness, comptime workload: Workload) !Metrics {
        if (workload.is_encode()) {
            return codec_metrics(&self.codec_fixtures[codec_index(workload)], false);
        }
        if (workload.is_decode()) {
            return codec_metrics(&self.codec_fixtures[codec_index(workload)], true);
        }
        if (workload.is_compact()) {
            return compact_metrics(&self.compact_fixture, compact_case_index(workload));
        }
        const snapshot_bytes = try multiply_u64(snapshot_page_count, small_page_size_bytes);
        return switch (workload) {
            .apply_checked => apply_metrics(
                snapshot_bytes,
                self.snapshot.checked.length_bytes,
                true,
            ),
            .apply_no_checksum => apply_metrics(
                snapshot_bytes,
                self.snapshot.no_checksum.length_bytes,
                false,
            ),
            else => unreachable,
        };
    }
};

fn verify_encode(harness: *Harness, fixture_index: usize, outcome: Outcome) !void {
    const fixture = &harness.codec_fixtures[fixture_index];
    const actual = harness.encode_workspace.slice();
    if (!std.mem.eql(u8, actual, fixture.encoded.slice())) return error.EncodeBytesMismatch;
    if (digest_bytes(actual) != fixture.encoded.digest) return error.EncodeDigestMismatch;
    if (!std.meta.eql(outcome.verified, fixture.encoded.verified)) {
        return error.EncodeVerifiedMismatch;
    }
    const expected_fingerprint = encoded_observation(actual, outcome.verified);
    if (outcome.fingerprint != expected_fingerprint) return error.EncodeFingerprintMismatch;
}

fn verify_decode(harness: *Harness, fixture_index: usize, outcome: Outcome) !void {
    const fixture = &harness.codec_fixtures[fixture_index];
    if (!std.meta.eql(outcome.verified, fixture.encoded.verified)) {
        return error.DecodeVerifiedMismatch;
    }
    const decoded = harness.decode_workspace.page[0..fixture.page_size_bytes];
    if (!std.mem.eql(u8, decoded, fixture.page_slice())) return error.DecodePageMismatch;
    if (digest_bytes(decoded) != fixture.page_digest) return error.DecodeDigestMismatch;
    const expected_fingerprint = page_bytes_observation(0, 1, decoded) ^
        outcome.verified.trailer.file_checksum.value;
    if (outcome.fingerprint != expected_fingerprint) return error.DecodeFingerprintMismatch;
}

fn verify_compact_run(harness: *Harness, case_index: usize, outcome: Outcome) !void {
    const expected = &harness.compact_fixture.expected_outputs[case_index];
    const actual = harness.compact_workspace.slice();
    if (!std.mem.eql(u8, actual, expected.slice())) return error.CompactionBytesMismatch;
    if (digest_bytes(actual) != expected.digest) return error.CompactionDigestMismatch;
    if (!std.meta.eql(outcome.verified, expected.verified)) {
        return error.CompactionVerifiedMismatch;
    }
    if (outcome.fingerprint != encoded_observation(actual, outcome.verified)) {
        return error.CompactionFingerprintMismatch;
    }
    try verify_compacted_bytes(harness, case_index, actual);
}

fn verify_apply(harness: *Harness, outcome: Outcome, no_checksum: bool) !void {
    const expected = if (no_checksum) &harness.snapshot.no_checksum else &harness.snapshot.checked;
    if (!std.meta.eql(outcome.verified, expected.verified)) return error.ApplyVerifiedMismatch;
    const backend = &harness.apply_workspace.backend_state;
    if (backend.published_length_bytes != apply_database_capacity_bytes or backend.active) {
        return error.ApplyStateMismatch;
    }
    const published = backend.published[0..backend.published_length_bytes];
    const expected_image = std.mem.asBytes(&harness.snapshot.pages);
    if (!std.mem.eql(u8, published, expected_image)) return error.ApplyImageMismatch;
    if (digest_bytes(published) != harness.snapshot.image_digest) return error.ApplyDigestMismatch;
    const fingerprint = observe_bytes(published) ^ outcome.verified.trailer.file_checksum.value;
    if (outcome.fingerprint != fingerprint) return error.ApplyFingerprintMismatch;
}

fn verify_codec_file(workspace: *DecodeWorkspace, fixture: *const CodecFixture) !void {
    const outcome = try workspace.execute(fixture.encoded.slice());
    if (!std.meta.eql(outcome.verified, fixture.encoded.verified)) {
        return error.CodecFixtureMismatch;
    }
    const decoded = workspace.page[0..fixture.page_size_bytes];
    if (!std.mem.eql(u8, decoded, fixture.page_slice())) return error.CodecFixturePageMismatch;
    if (digest_bytes(decoded) != fixture.page_digest) return error.CodecFixtureDigestMismatch;
}

fn verify_snapshot_file(
    workspace: *DecodeWorkspace,
    snapshot: *const SnapshotFixture,
    no_checksum: bool,
) !void {
    const encoded = if (no_checksum) &snapshot.no_checksum else &snapshot.checked;
    var decoder = try make_decoder(workspace, encoded.slice());
    var page_index: usize = 0;
    for (0..decoder.event_budget()) |_| switch (try decoder.next()) {
        .header, .page_block_complete => {},
        .unverified_page => |page| {
            if (page_index >= snapshot.pages.len or page.header.page_number != page_index + 1 or
                !std.mem.eql(u8, page.data, &snapshot.pages[page_index]))
            {
                return error.SnapshotPageMismatch;
            }
            page_index += 1;
        },
        .verified => |verified| {
            if (page_index != snapshot.pages.len or verified.header.no_checksum() != no_checksum) {
                return error.SnapshotVerifiedMismatch;
            }
            return;
        },
    };
    return error.DecoderDidNotTerminate;
}

fn verify_compacted_bytes(harness: *Harness, case_index: usize, bytes: []const u8) !void {
    var decoder = try make_decoder(&harness.decode_workspace, bytes);
    var page_index: usize = 0;
    var image_digest = digest_initial;
    const commit = compact_commits[case_index];
    for (0..decoder.event_budget()) |_| switch (try decoder.next()) {
        .header, .page_block_complete => {},
        .unverified_page => |page| {
            if (page_index >= commit) return error.CompactedPageMismatch;
            const expected = &harness.compact_fixture.expected_images[case_index][page_index];
            if (page.header.page_number != page_index + 1 or
                !std.mem.eql(u8, page.data, expected))
            {
                return error.CompactedPageMismatch;
            }
            image_digest = digest_update(image_digest, page.data);
            page_index += 1;
        },
        .verified => |verified| {
            try verify_compacted_result(
                harness,
                case_index,
                page_index,
                image_digest,
                verified,
            );
            return;
        },
    };
    return error.DecoderDidNotTerminate;
}

fn verify_compacted_result(
    harness: *const Harness,
    case_index: usize,
    page_count: usize,
    image_digest: u64,
    verified: ltx.VerifiedLTX,
) !void {
    const input_count = compact_input_counts[case_index];
    const header = verified.header;
    if (page_count != compact_commits[case_index] or
        verified.page_count != compact_commits[case_index] or header.flags != 0 or
        header.page_size != small_page_size_bytes or header.commit != compact_commits[case_index] or
        header.min_txid.value != 1 or header.max_txid.value != input_count or
        header.timestamp_ms != compact_timestamp_ms(input_count) or
        header.pre_apply_checksum.value != 0)
    {
        return error.CompactedResultMismatch;
    }
    if (header.wal_offset != 0 or header.wal_size != 0 or header.wal_salt_1 != 0 or
        header.wal_salt_2 != 0 or header.node_id != 0 or
        verified.trailer.post_apply_checksum.value !=
            harness.compact_fixture.expected_checksums[case_index].value)
    {
        return error.CompactedMetadataMismatch;
    }
    if (image_digest != harness.compact_fixture.expected_digests[case_index]) {
        return error.CompactedDigestMismatch;
    }
}

fn make_decoder(workspace: *DecodeWorkspace, bytes: []const u8) !ltx.Decoder {
    workspace.source = ltx.SliceReader.init(bytes);
    return ltx.Decoder.init(
        .v3,
        codec_limits,
        workspace.source.reader(),
        &workspace.page,
        &workspace.compressed,
        &workspace.index,
    );
}

fn require_equal_metrics(expected: Metrics, outcome: Outcome) !void {
    if (outcome.result_wire_bytes != expected.result_wire_bytes) return error.WireCountMismatch;
    if (outcome.decoded_events != expected.decoded_events) return error.EventCountMismatch;
    if (outcome.decoded_pages != expected.decoded_pages) return error.DecodedPageCountMismatch;
    if (outcome.emitted_pages != expected.emitted_pages) return error.EmittedPageCountMismatch;
    if (outcome.stage_callbacks != expected.stage_callbacks) return error.StageCountMismatch;
    if (outcome.read_callbacks != expected.read_callbacks) return error.ReadCountMismatch;
    if (outcome.publish_callbacks != expected.publish_callbacks) return error.PublishCountMismatch;
}

fn codec_metrics(fixture: *const CodecFixture, decode: bool) Metrics {
    var result = base_metrics(fixture.page_size_bytes, fixture.encoded.length_bytes, 1, 1);
    if (decode) {
        result.decoded_events = 4;
        result.decoded_pages = 1;
    }
    return result;
}

fn base_metrics(logical: u64, wire: usize, work_pages: u64, emitted: u64) Metrics {
    return .{
        .logical_bytes = logical,
        .wire_bytes = @intCast(wire),
        .result_wire_bytes = @intCast(wire),
        .work_pages = work_pages,
        .decoded_events = 0,
        .decoded_pages = 0,
        .emitted_pages = emitted,
        .stage_callbacks = 0,
        .read_callbacks = 0,
        .publish_callbacks = 0,
    };
}

fn compact_metrics(fixture: *const CompactFixture, case_index: usize) !Metrics {
    const input_count = compact_input_counts[case_index];
    var wire_bytes: u64 = 0;
    for (fixture.files[0..input_count]) |file| {
        wire_bytes = try std.math.add(u64, wire_bytes, file.length_bytes);
    }
    const decoded_pages = compact_decoded_page_counts[case_index];
    return .{
        .logical_bytes = try multiply_u64(decoded_pages, small_page_size_bytes),
        .wire_bytes = wire_bytes,
        .result_wire_bytes = fixture.expected_outputs[case_index].length_bytes,
        .work_pages = decoded_pages,
        .decoded_events = decoded_pages + 3 * input_count,
        .decoded_pages = decoded_pages,
        .emitted_pages = compact_commits[case_index],
        .stage_callbacks = 0,
        .read_callbacks = 0,
        .publish_callbacks = 0,
    };
}

fn apply_metrics(logical: u64, wire: usize, checked: bool) Metrics {
    var result = base_metrics(logical, wire, snapshot_page_count, snapshot_page_count);
    result.decoded_events = snapshot_page_count + 3;
    result.decoded_pages = snapshot_page_count;
    result.stage_callbacks = snapshot_page_count;
    result.read_callbacks = if (checked) snapshot_page_count else 0;
    result.publish_callbacks = 1;
    return result;
}

fn copy_encoded(
    target: *EncodedFile,
    workspace: *const EncodeWorkspace,
    verified: ltx.VerifiedLTX,
) void {
    std.debug.assert(workspace.length_bytes <= target.bytes.len);
    @memcpy(target.bytes[0..workspace.length_bytes], workspace.slice());
    target.length_bytes = workspace.length_bytes;
    target.digest = digest_bytes(target.slice());
    target.verified = verified;
}

fn copy_compacted(
    target: *EncodedFile,
    workspace: *const CompactWorkspace,
    verified: ltx.VerifiedLTX,
) void {
    std.debug.assert(workspace.length_bytes <= target.bytes.len);
    @memcpy(target.bytes[0..workspace.length_bytes], workspace.slice());
    target.length_bytes = workspace.length_bytes;
    target.digest = digest_bytes(target.slice());
    target.verified = verified;
}

fn encode_fixture_file(
    target: *EncodedFile,
    workspace: *EncodeWorkspace,
    header: ltx.Header,
    pages: []const PageSpec,
    checksum: ltx.Checksum,
) !void {
    const outcome = try workspace.execute(header, pages, checksum);
    copy_encoded(target, workspace, outcome.verified);
}

fn make_outcome(verified: ltx.VerifiedLTX, bytes: []const u8, pages: u32) Outcome {
    return .{
        .verified = verified,
        .result_wire_bytes = @intCast(bytes.len),
        .emitted_pages = pages,
        .fingerprint = encoded_observation(bytes, verified),
    };
}

fn encoded_observation(bytes: []const u8, verified: ltx.VerifiedLTX) u64 {
    return observe_bytes(bytes) ^ verified.trailer.file_checksum.value ^
        verified.trailer.post_apply_checksum.value;
}

fn make_header(
    flags: u32,
    page_size_bytes: usize,
    commit: usize,
    txid: usize,
    pre_checksum: ltx.Checksum,
) ltx.Header {
    return .{
        .flags = flags,
        .page_size = @intCast(page_size_bytes),
        .commit = @intCast(commit),
        .min_txid = .init(@intCast(txid)),
        .max_txid = .init(@intCast(txid)),
        .timestamp_ms = 0,
        .pre_apply_checksum = pre_checksum,
        .wal_offset = 0,
        .wal_size = 0,
        .wal_salt_1 = 0,
        .wal_salt_2 = 0,
        .node_id = 0,
    };
}

fn make_compact_header(commit: usize, txid: usize, pre_checksum: ltx.Checksum) ltx.Header {
    var header = make_header(0, small_page_size_bytes, commit, txid, pre_checksum);
    header.timestamp_ms = compact_timestamp_ms(txid);
    header.wal_offset = @intCast(txid * small_page_size_bytes);
    header.wal_size = @intCast(small_page_size_bytes);
    header.wal_salt_1 = @intCast(0x1000 + txid);
    header.wal_salt_2 = @intCast(0x2000 + txid);
    header.node_id = 0x4c54_5800 + txid;
    return header;
}

fn compact_timestamp_ms(txid: usize) i64 {
    return @intCast(txid * 100);
}

fn checksum_pages(pages: []const PageSpec) !ltx.Checksum {
    var checksum = ltx.rolling_checksum_initial();
    for (pages) |page| {
        checksum = try ltx.rolling_checksum_add(
            checksum,
            try ltx.checksum_page(page.page_number, page.data),
        );
    }
    return checksum;
}

fn checksum_contiguous(pages: []const [small_page_size_bytes]u8) !ltx.Checksum {
    var checksum = ltx.rolling_checksum_initial();
    for (pages, 0..) |*page, index| {
        checksum = try ltx.rolling_checksum_add(
            checksum,
            try ltx.checksum_page(@intCast(index + 1), page),
        );
    }
    return checksum;
}

fn page_specs_four(
    pages: *const [compact_initial_page_count][small_page_size_bytes]u8,
) [compact_initial_page_count]PageSpec {
    var result: [compact_initial_page_count]PageSpec = undefined;
    for (&result, 0..) |*spec, index| {
        spec.* = .{ .page_number = @intCast(index + 1), .data = &pages[index] };
    }
    return result;
}

fn codec_index(workload: Workload) usize {
    return switch (workload) {
        .encode_4k_zero, .decode_4k_zero => 0,
        .encode_4k_mixed, .decode_4k_mixed => 1,
        .encode_4k_random, .decode_4k_random => 2,
        .encode_64k_zero, .decode_64k_zero => 3,
        .encode_64k_mixed, .decode_64k_mixed => 4,
        .encode_64k_random, .decode_64k_random => 5,
        else => unreachable,
    };
}

fn compact_case_index(workload: Workload) usize {
    return switch (workload) {
        .compact_1 => 0,
        .compact_4 => 1,
        .compact_16 => 2,
        else => unreachable,
    };
}

pub fn compact_input_count(workload: Workload) usize {
    return compact_input_counts[compact_case_index(workload)];
}

fn fill_pattern(bytes: []u8, pattern: Pattern, seed: u32) void {
    switch (pattern) {
        .zero => @memset(bytes, 0),
        .random => fill_lcg(bytes, seed *% 0x9e37_79b9),
        .mixed => {
            fill_lcg(bytes, seed *% 0x85eb_ca6b);
            var offset: usize = 0;
            while (offset < bytes.len) : (offset += 193) {
                const end = @min(offset + 97, bytes.len);
                @memset(bytes[offset..end], @truncate(seed *% 37));
            }
        },
    }
}

fn fill_snapshot_pages(pages: *[snapshot_page_count][small_page_size_bytes]u8) void {
    @memset(&pages[0], 0);
    fill_lcg(&pages[1], 0x1234_5678);
    fill_stripes(&pages[2], 0x33, 0xcc);
    fill_lcg(&pages[3], 0x9e37_79b9);
    var offset: usize = 0;
    while (offset < small_page_size_bytes) : (offset += 127) pages[3][offset] = 0x5a;
}

fn fill_compact_page(page: *[small_page_size_bytes]u8, input_index: usize, page_number: u32) void {
    const index: u32 = @intCast(input_index + 1);
    fill_lcg(page, index *% 0x1020_3041 +% page_number *% 0x9e37_79b9);
    const fill: u8 = @truncate(input_index * 17 + page_number * 11);
    var offset: usize = (input_index + page_number) % 53;
    while (offset < page.len) : (offset += 101 + input_index % 13) {
        const end = @min(offset + 29, page.len);
        @memset(page[offset..end], fill);
    }
}

fn fill_lcg(bytes: []u8, seed: u32) void {
    var state = seed;
    for (bytes) |*byte| {
        state = state *% 1_664_525 +% 1_013_904_223;
        byte.* = @truncate(state >> 24);
    }
}

fn fill_stripes(bytes: []u8, first: u8, second: u8) void {
    var offset: usize = 0;
    while (offset < bytes.len) : (offset += 64) {
        const end = @min(offset + 64, bytes.len);
        @memset(bytes[offset..end], if ((offset / 64) % 2 == 0) first else second);
    }
}

fn page_observation(previous: u64, page: ltx.UnverifiedPage) u64 {
    return page_bytes_observation(previous, page.header.page_number, page.data);
}

fn page_bytes_observation(previous: u64, page_number: u32, bytes: []const u8) u64 {
    return std.math.rotl(u64, previous, 7) ^ page_number ^ observe_bytes(bytes);
}

fn observe_bytes(bytes: []const u8) u64 {
    std.debug.assert(bytes.len != 0);
    std.debug.assert(bytes.len <= max_file_bytes);
    // Keep timed output memory observable without adding a whole-buffer digest
    // to the operation being measured. Full digests are checked after timing.
    const positions = [5]usize{ 0, bytes.len / 4, bytes.len / 2, bytes.len * 3 / 4, bytes.len - 1 };
    var value: u64 = @intCast(bytes.len);
    for (positions, 0..) |position, index| {
        value = std.math.rotl(u64, value, 11) ^
            (@as(u64, bytes[position]) << @as(u6, @intCast(index * 8)));
    }
    std.mem.doNotOptimizeAway(bytes);
    std.mem.doNotOptimizeAway(value);
    return value;
}

fn digest_bytes(bytes: []const u8) u64 {
    std.debug.assert(bytes.len <= max_file_bytes);
    return digest_update(digest_initial, bytes);
}

const digest_initial: u64 = 0xcbf2_9ce4_8422_2325;

fn digest_update(initial: u64, bytes: []const u8) u64 {
    var digest = initial;
    var index: usize = 0;
    while (index < bytes.len) : (index += 1) {
        digest = (digest ^ bytes[index]) *% 0x0000_0100_0000_01b3;
    }
    return digest;
}

fn multiply_u64(left: anytype, right: anytype) !u64 {
    return std.math.mul(u64, @intCast(left), @intCast(right));
}
