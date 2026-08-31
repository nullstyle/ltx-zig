//! Replication planning and level management.
//!
//! The level ladder, restore planner, and compaction planner are pure ports
//! of the pinned Celld crate's `compaction_level.rs`, `replica.rs`
//! (`calc_restore_plan` and its level-cursor algorithm), and
//! `replica_compactor.rs` planning half. The executors compose the existing
//! `ltx` codec with an `ltx_object` client: level compaction through
//! `ltx.Compactor` and restore through `ltx.StagedApplier` with an injected
//! apply backend. Everything runs over caller-owned storage; this module
//! allocates nothing.

const std = @import("std");
const ltx = @import("ltx");
const object = @import("ltx_object");

pub const Error = error{
    InvalidLevels,
    InvalidLevel,
    PlanCapacityExceeded,
    TxNotAvailable,
    NonContiguousPlan,
    CompactionNotAvailable,
    ObjectIdentityMismatch,
    StorageFailure,
} || ltx.Error || object.Error;

// ── Compaction levels ─────────────────────────────────────────────────────────

/// One non-snapshot compaction level: its number and the interval since the
/// preceding level at which it compacts. Level zero always has a zero
/// interval.
pub const CompactionLevel = struct {
    level: u8,
    interval_ms: u64,
};

/// The canonical Litestream v0.5.16 ladder: L0 immediate, then 30 seconds,
/// 5 minutes, and 1 hour.
pub const default_levels = [4]CompactionLevel{
    .{ .level = 0, .interval_ms = 0 },
    .{ .level = 1, .interval_ms = 30_000 },
    .{ .level = 2, .interval_ms = 300_000 },
    .{ .level = 3, .interval_ms = 3_600_000 },
};

/// A validated, ordered ladder over caller-owned level storage.
pub const CompactionLevels = struct {
    levels: []const CompactionLevel,

    pub fn validate(self: CompactionLevels) error{InvalidLevels}!void {
        if (self.levels.len == 0) return error.InvalidLevels;
        for (self.levels, 0..) |entry, index| {
            if (entry.level != index) return error.InvalidLevels;
            if (entry.level >= ltx.snapshot_level) return error.InvalidLevels;
            const zero = entry.interval_ms == 0;
            if ((entry.level == 0) != zero) return error.InvalidLevels;
        }
    }

    pub fn max_level(self: CompactionLevels) u8 {
        std.debug.assert(self.levels.len >= 1);
        return @intCast(self.levels.len - 1);
    }

    pub fn contains(self: CompactionLevels, level: u8) bool {
        if (level == ltx.snapshot_level) return true;
        return level < self.levels.len;
    }

    pub fn interval_ms(self: CompactionLevels, level: u8) Error!u64 {
        if (level == ltx.snapshot_level) return error.InvalidLevel;
        if (level >= self.levels.len) return error.InvalidLevel;
        return self.levels[level].interval_ms;
    }

    /// The preceding level, including the level before the snapshot level.
    pub fn previous_level(self: CompactionLevels, level: u8) ?u8 {
        if (level == ltx.snapshot_level) return self.max_level();
        if (level == 0) return null;
        return level - 1;
    }

    /// The following level, including the snapshot transition.
    pub fn next_level(self: CompactionLevels, level: u8) ?u8 {
        if (level == ltx.snapshot_level) return null;
        if (level == self.max_level()) return ltx.snapshot_level;
        const following = level + 1;
        if (!self.contains(following)) return null;
        return following;
    }

    /// Start of the current interval, in Unix milliseconds: the largest
    /// interval boundary at or before `now_ms`.
    pub fn previous_compaction_at_ms(
        self: CompactionLevels,
        level: u8,
        now_ms: u64,
    ) Error!u64 {
        const interval = try self.interval_ms(level);
        if (interval == 0) return now_ms;
        return now_ms - (now_ms % interval);
    }

    /// Start of the next interval, in Unix milliseconds.
    pub fn next_compaction_at_ms(
        self: CompactionLevels,
        level: u8,
        now_ms: u64,
    ) Error!u64 {
        const previous = try self.previous_compaction_at_ms(level, now_ms);
        const interval = try self.interval_ms(level);
        return std.math.add(u64, previous, interval) catch return error.InvalidLevels;
    }
};

// ── Restore planning ──────────────────────────────────────────────────────────

/// Computes the ordered file list needed to restore the database at
/// `target_txid` (zero means latest available).
///
/// `level_lists` holds one ascending listing per level, index zero through
/// the snapshot level; the `Client.list` ordering contract is required. The
/// plan is written to the filled prefix of `destination`.
///
/// Ports Celld's `calc_restore_plan`: the newest qualifying snapshot anchors
/// the plan, then per-level cursors greedily extend the longest contiguous
/// TXID range. A latest-restore plan whose remaining files leave a gap fails
/// the tail-contiguity check; unreachable targets return `TxNotAvailable`.
pub fn calc_restore_plan(
    level_lists: []const []const ltx.FileInfo,
    target_txid: ltx.TXID,
    destination: []ltx.FileInfo,
) Error![]const ltx.FileInfo {
    if (level_lists.len != ltx.snapshot_level + 1) return error.InvalidLevel;
    var plan_length: usize = 0;
    var current_max = ltx.TXID.init(0);

    const snapshot = newest_snapshot(level_lists[ltx.snapshot_level], target_txid);
    if (snapshot) |info| {
        if (destination.len == 0) return error.PlanCapacityExceeded;
        destination[0] = info;
        plan_length = 1;
        current_max = info.max_txid;
    }
    if (target_txid.value != 0 and current_max.value >= target_txid.value) {
        return destination[0..plan_length];
    }

    var cursors: [ltx.snapshot_level]RestoreCursor = undefined;
    for (0..cursors.len) |level| {
        cursors[level] = RestoreCursor.init(level_lists[level]);
    }

    while (true) {
        var best: ?usize = null;
        for (&cursors, 0..) |*cursor, index| {
            cursor.refresh(current_max, target_txid);
            if (cursor.candidate == null) continue;
            if (best == null) {
                best = index;
                continue;
            }
            const incumbent = cursors[best.?].candidate.?;
            const candidate = cursor.candidate.?;
            if (restore_candidate_better(incumbent, candidate)) best = index;
        }
        const index = best orelse break;
        const candidate = cursors[index].candidate.?;
        cursors[index].candidate = null;
        current_max = candidate.max_txid;
        if (plan_length == destination.len) return error.PlanCapacityExceeded;
        destination[plan_length] = candidate;
        plan_length += 1;
        if (target_txid.value != 0 and current_max.value >= target_txid.value) {
            return destination[0..plan_length];
        }
    }

    if (plan_length != 0 and target_txid.value == 0) {
        for (&cursors) |*cursor| {
            cursor.ensure_current();
            if (cursor.current) |info| {
                const expected = contiguous_predecessor(current_max) orelse continue;
                if (info.min_txid.value > expected.value) {
                    return error.NonContiguousPlan;
                }
            }
        }
    }
    if (plan_length == 0) return error.TxNotAvailable;
    if (target_txid.value != 0 and current_max.value < target_txid.value) {
        return error.TxNotAvailable;
    }
    return destination[0..plan_length];
}

/// The TXID a file must start after to continue from `current`: its value
/// plus one, or null when no continuation is representable.
fn contiguous_predecessor(current: ltx.TXID) ?ltx.TXID {
    const next = std.math.add(u64, current.value, 1) catch return null;
    return ltx.TXID.init(next);
}

fn newest_snapshot(
    listing: []const ltx.FileInfo,
    target_txid: ltx.TXID,
) ?ltx.FileInfo {
    var snapshot: ?ltx.FileInfo = null;
    for (listing) |info| {
        if (target_txid.value != 0 and info.max_txid.value > target_txid.value) {
            continue;
        }
        snapshot = info;
    }
    return snapshot;
}

/// One level's streaming view during restore planning; ports Celld's
/// `RestoreLevelCursor`. The listing must be sorted ascending.
const RestoreCursor = struct {
    files: []const ltx.FileInfo,
    index: usize = 0,
    current: ?ltx.FileInfo = null,
    candidate: ?ltx.FileInfo = null,
    done: bool = false,

    fn init(files: []const ltx.FileInfo) RestoreCursor {
        return .{ .files = files };
    }

    /// Advances while files could be contiguous with `current_max`, keeping
    /// the best eligible candidate.
    fn refresh(self: *RestoreCursor, current_max: ltx.TXID, target_txid: ltx.TXID) void {
        if (self.done) return;
        if (self.candidate) |info| {
            if (info.max_txid.value <= current_max.value) self.candidate = null;
        }
        while (true) {
            self.ensure_current();
            if (self.done) return;
            const info = self.current.?;
            const expected = contiguous_predecessor(current_max) orelse return;
            if (info.min_txid.value > expected.value) return;
            self.current = null;
            if (info.max_txid.value <= current_max.value) continue;
            if (target_txid.value != 0 and info.max_txid.value > target_txid.value) {
                continue;
            }
            if (self.candidate == null or
                restore_candidate_better(self.candidate.?, info))
            {
                self.candidate = info;
            }
        }
    }

    fn ensure_current(self: *RestoreCursor) void {
        if (self.done or self.current != null) return;
        if (self.index >= self.files.len) {
            self.done = true;
            return;
        }
        self.current = self.files[self.index];
        self.index += 1;
    }
};

/// True when `next` is a strictly better restore candidate than `current`:
/// longer reach first, then wider coverage, then a higher compaction level,
/// then an earlier creation timestamp.
fn restore_candidate_better(current: ltx.FileInfo, next: ltx.FileInfo) bool {
    if (next.max_txid.value != current.max_txid.value) {
        return next.max_txid.value > current.max_txid.value;
    }
    if (next.min_txid.value != current.min_txid.value) {
        return next.min_txid.value < current.min_txid.value;
    }
    if (next.level != current.level) {
        return next.level > current.level;
    }
    if (next.created_at_ms != null and current.created_at_ms != null) {
        return next.created_at_ms.? < current.created_at_ms.?;
    }
    return false;
}

// ── Compaction and retention planning ─────────────────────────────────────────

pub const CompactionPlan = struct {
    /// The leading prefix of the source listing to compact; zero means no
    /// work is available.
    input_count: usize,
    /// The TXID the destination level continues from: its current maximum
    /// plus one.
    seek_txid: ltx.TXID,
};

/// Selects the compaction inputs for one destination level from the source
/// level's ascending listing. The prefix is bounded by `max_inputs` files
/// and `max_input_bytes` of aggregate `FileInfo.size_bytes`, and must continue
/// the destination level exactly. Gaps between chosen files are not repaired
/// here; the codec compactor rejects them.
pub fn plan_compaction(
    source: []const ltx.FileInfo,
    destination: []const ltx.FileInfo,
    max_inputs: usize,
    max_input_bytes: u64,
) Error!CompactionPlan {
    if (max_inputs == 0 or max_input_bytes == 0) return error.InvalidLevels;
    var destination_max = ltx.TXID.init(0);
    for (destination) |info| {
        if (info.max_txid.value > destination_max.value) {
            destination_max = info.max_txid;
        }
    }
    const seek = contiguous_predecessor(destination_max) orelse
        return error.CompactionNotAvailable;

    var count: usize = 0;
    var total_bytes: u64 = 0;
    while (count < source.len and count < max_inputs) : (count += 1) {
        const next = std.math.add(u64, total_bytes, source[count].size_bytes) catch
            return error.CompactionNotAvailable;
        if (next > max_input_bytes) break;
        total_bytes = next;
    }
    if (count == 0) return .{ .input_count = 0, .seek_txid = seek };
    if (source[0].min_txid.value != seek.value) {
        return error.CompactionNotAvailable;
    }
    return .{ .input_count = count, .seek_txid = seek };
}

/// Returns the subset of `lower` whose TXID range is fully contained in some
/// file of `upper`, written to the filled prefix of `destination`. Those
/// files are safe to delete once `upper` is durable.
pub fn plan_retention(
    lower: []const ltx.FileInfo,
    upper: []const ltx.FileInfo,
    destination: []ltx.FileInfo,
) []const ltx.FileInfo {
    var count: usize = 0;
    for (lower) |info| {
        for (upper) |absorber| {
            if (absorber.min_txid.value <= info.min_txid.value and
                info.max_txid.value <= absorber.max_txid.value)
            {
                if (count == destination.len) return destination[0..count];
                destination[count] = info;
                count += 1;
                break;
            }
        }
    }
    return destination[0..count];
}

// ── Restore execution ─────────────────────────────────────────────────────────

/// Caller-owned storage for validating a restore plan without applying it.
/// Every object is decoded through EOF, including its index, trailer, file
/// checksum, and snapshot checksum. Object-key identities and cross-object
/// position continuity are also verified. The job allocates nothing.
pub const VerificationJob = struct {
    client: object.Client,
    codec_limits: ltx.Limits,
    read_workspace: []u8,
    page_workspace: []u8,
    compressed_workspace: []u8,
    index_workspace: []ltx.PageIndexEntry,

    pub fn run(self: *VerificationJob, plan: []const ltx.FileInfo) Error!ltx.Position {
        if (plan.len == 0) return error.TxNotAvailable;
        for (plan) |info| try validate_source_info(self.codec_limits, info);
        try self.validate_resource_aliases(plan);
        var position: ?ltx.Position = null;
        var page_size: ?u32 = null;
        for (plan) |info| {
            const verified = try self.verify_object(info);
            try verify_identity(verified, .{
                .min_txid = info.min_txid,
                .max_txid = info.max_txid,
            });
            if (position) |current| {
                try verified.check_contiguous(current);
                if (verified.header.page_size != page_size.?) {
                    return error.DatabasePageSizeMismatch;
                }
            } else if (verified.header.min_txid.value != 1) {
                return error.NonContiguousPlan;
            }
            position = verified.post_apply_position();
            page_size = verified.header.page_size;
        }
        return position.?;
    }

    fn verify_object(
        self: *VerificationJob,
        info: ltx.FileInfo,
    ) Error!ltx.VerifiedLTX {
        var source = try object.ObjectReader.init(
            self.client,
            info,
            self.read_workspace,
        );
        var decoder = try ltx.Decoder.init(
            .v3,
            self.codec_limits,
            source.reader(),
            self.page_workspace,
            self.compressed_workspace,
            self.index_workspace,
        );
        var event_count: u64 = 0;
        const event_limit = decoder.event_budget();
        while (event_count < event_limit) : (event_count += 1) {
            const event = decoder.next() catch |err| {
                if (source.failure()) |storage_error| return storage_error;
                return err;
            };
            switch (event) {
                .verified => |verified| return verified,
                else => {},
            }
        }
        return error.InvalidState;
    }

    fn validate_resource_aliases(
        self: *const VerificationJob,
        plan: []const ltx.FileInfo,
    ) Error!void {
        const controls = [_][]const u8{
            std.mem.asBytes(self),
            std.mem.sliceAsBytes(plan),
        };
        const workspaces = [_][]const u8{
            self.read_workspace,
            self.page_workspace,
            self.compressed_workspace,
            std.mem.sliceAsBytes(self.index_workspace),
        };
        if (ranges_overlap(&controls, &controls) or
            ranges_overlap(&workspaces, &workspaces) or
            ranges_overlap(&controls, &workspaces))
        {
            return error.WorkspaceAliasing;
        }
    }
};

const restore_temporary_suffix = ".restore-tmp";
const copy_chunk_bytes = 4096;

/// Filesystem apply backend for restore-to-path: one destination database
/// file published by tmp-write, sync, and rename after every verified
/// transition. The image before publication is private staging.
pub const RestoreBackend = struct {
    dir: std.Io.Dir,
    io: std.Io,
    destination_name: []const u8,
    temporary_name: [std.Io.Dir.max_path_bytes]u8 = undefined,
    temporary_name_bytes: usize = 0,
    stage_file: ?std.Io.File = null,
    current_value: ltx.ApplyCurrent = .{
        .position = .{
            .txid = ltx.TXID.init(0),
            .post_apply_checksum = ltx.Checksum.init(0),
        },
        .page_size = null,
    },
    current_image_size_bytes: u64 = 0,
    copy_workspace: [copy_chunk_bytes]u8 = undefined,

    pub fn init(
        dir: std.Io.Dir,
        io: std.Io,
        destination_name: []const u8,
    ) Error!RestoreBackend {
        if (destination_name.len + restore_temporary_suffix.len >
            std.Io.Dir.max_path_bytes)
        {
            return error.StorageFailure;
        }
        var self = RestoreBackend{
            .dir = dir,
            .io = io,
            .destination_name = destination_name,
        };
        @memcpy(self.temporary_name[0..destination_name.len], destination_name);
        @memcpy(
            self.temporary_name[destination_name.len..][0..restore_temporary_suffix.len],
            restore_temporary_suffix,
        );
        self.temporary_name_bytes = destination_name.len + restore_temporary_suffix.len;
        return self;
    }

    pub fn backend(self: *RestoreBackend) ltx.ApplyBackend {
        return .{
            .context = self,
            .begin_fn = begin_callback,
            .stage_page_fn = stage_page_callback,
            .read_page_fn = read_page_callback,
            .publish_fn = publish_callback,
            .abort_fn = abort_callback,
        };
    }

    /// The position and page size of the published image.
    pub fn current(self: *const RestoreBackend) ltx.ApplyCurrent {
        return self.current_value;
    }

    fn temporary_path(self: *const RestoreBackend) []const u8 {
        return self.temporary_name[0..self.temporary_name_bytes];
    }

    fn begin(self: *RestoreBackend, plan: ltx.ApplyPlan) error{ApplyBeginFailure}!ltx.ApplyCurrent {
        var file = self.dir.createFile(
            self.io,
            self.temporary_path(),
            .{ .truncate = true, .read = true },
        ) catch return error.ApplyBeginFailure;
        var succeeded = false;
        defer if (!succeeded) {
            file.close(self.io);
            self.dir.deleteFile(self.io, self.temporary_path()) catch {};
        };
        const replaces_image = plan.mode == .replace_snapshot and
            plan.header.is_snapshot();
        if (!replaces_image and self.current_value.page_size != null) {
            if (plan.header.page_size != self.current_value.page_size.?) {
                return error.ApplyBeginFailure;
            }
            copy_published_image(self, &file) catch return error.ApplyBeginFailure;
        }
        file.setLength(self.io, plan.final_database_size_bytes) catch
            return error.ApplyBeginFailure;
        succeeded = true;
        self.stage_file = file;
        return self.current_value;
    }

    /// Copies the published image into private staging before an incremental
    /// apply resizes it.
    fn copy_published_image(self: *RestoreBackend, destination: *std.Io.File) !void {
        var source = self.dir.openFile(self.io, self.destination_name, .{}) catch
            return error.StorageFailure;
        defer source.close(self.io);
        const size = self.current_image_size_bytes;
        var offset: u64 = 0;
        while (offset < size) {
            const length: usize = @intCast(@min(size - offset, copy_chunk_bytes));
            const chunk = self.copy_workspace[0..length];
            const read = source.readPositionalAll(self.io, chunk, offset) catch
                return error.StorageFailure;
            if (read != length) return error.StorageFailure;
            destination.writePositionalAll(self.io, chunk, offset) catch
                return error.StorageFailure;
            offset += length;
        }
    }

    fn stage_page(self: *RestoreBackend, page: ltx.StagedPage) error{ApplyStageFailure}!void {
        const file = self.stage_file orelse return error.ApplyStageFailure;
        file.writePositionalAll(self.io, page.data, page.offset_bytes) catch
            return error.ApplyStageFailure;
    }

    fn read_page(
        self: *RestoreBackend,
        page_number: u32,
        destination: []u8,
    ) error{ApplyReadFailure}!void {
        const file = self.stage_file orelse return error.ApplyReadFailure;
        const page_size: u64 = destination.len;
        const offset = std.math.mul(u64, page_number - 1, page_size) catch
            return error.ApplyReadFailure;
        const read = file.readPositionalAll(self.io, destination, offset) catch
            return error.ApplyReadFailure;
        if (read != destination.len) return error.ApplyReadFailure;
    }

    fn publish(
        self: *RestoreBackend,
        expected: ltx.ApplyCurrent,
        verified: ltx.VerifiedLTX,
    ) error{ ApplyPublishFailure, NonContiguousTransition }!void {
        if (!std.meta.eql(expected.position, self.current_value.position) or
            expected.page_size != self.current_value.page_size)
        {
            return error.NonContiguousTransition;
        }
        const file = self.stage_file orelse return error.ApplyPublishFailure;
        file.sync(self.io) catch {
            file.close(self.io);
            self.stage_file = null;
            return error.ApplyPublishFailure;
        };
        file.close(self.io);
        self.stage_file = null;
        self.dir.rename(
            self.temporary_path(),
            self.dir,
            self.destination_name,
            self.io,
        ) catch return error.ApplyPublishFailure;
        self.current_value = .{
            .position = verified.post_apply_position(),
            .page_size = verified.header.page_size,
        };
        self.current_image_size_bytes = @as(u64, verified.header.commit) *
            @as(u64, verified.header.page_size);
    }

    fn abort(self: *RestoreBackend) void {
        if (self.stage_file) |file| {
            file.close(self.io);
            self.stage_file = null;
        }
        self.dir.deleteFile(self.io, self.temporary_path()) catch {};
    }
};

fn begin_callback(
    context: *anyopaque,
    plan: ltx.ApplyPlan,
) error{ApplyBeginFailure}!ltx.ApplyCurrent {
    const self: *RestoreBackend = @ptrCast(@alignCast(context));
    return self.begin(plan);
}

fn stage_page_callback(
    context: *anyopaque,
    page: ltx.StagedPage,
) error{ApplyStageFailure}!void {
    const self: *RestoreBackend = @ptrCast(@alignCast(context));
    return self.stage_page(page);
}

fn read_page_callback(
    context: *anyopaque,
    page_number: u32,
    destination: []u8,
) error{ApplyReadFailure}!void {
    const self: *RestoreBackend = @ptrCast(@alignCast(context));
    return self.read_page(page_number, destination);
}

fn publish_callback(
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
    const self: *RestoreBackend = @ptrCast(@alignCast(context));
    return self.publish(expected, verified);
}

fn abort_callback(context: *anyopaque) void {
    const self: *RestoreBackend = @ptrCast(@alignCast(context));
    self.abort();
}

/// Rejects a decoded header whose TXID range does not match the object key
/// selected by the restore plan. The inner backend does not begin staging
/// until the identity matches.
const RestoreIdentityGuard = struct {
    inner: ltx.ApplyBackend,
    expected: ltx.FileIdentity,
    mismatch: bool = false,

    fn backend(self: *RestoreIdentityGuard) ltx.ApplyBackend {
        return .{
            .context = self,
            .begin_fn = begin,
            .stage_page_fn = stage_page,
            .read_page_fn = read_page,
            .publish_fn = publish,
            .abort_fn = abort,
            .backing_bytes = self.inner.backing_bytes,
        };
    }

    fn begin(
        context: *anyopaque,
        plan: ltx.ApplyPlan,
    ) error{ApplyBeginFailure}!ltx.ApplyCurrent {
        const self: *RestoreIdentityGuard = @ptrCast(@alignCast(context));
        if (plan.header.min_txid.value != self.expected.min_txid.value or
            plan.header.max_txid.value != self.expected.max_txid.value)
        {
            self.mismatch = true;
            return error.ApplyBeginFailure;
        }
        return self.inner.begin_fn(self.inner.context, plan);
    }

    fn stage_page(
        context: *anyopaque,
        page: ltx.StagedPage,
    ) error{ApplyStageFailure}!void {
        const self: *RestoreIdentityGuard = @ptrCast(@alignCast(context));
        return self.inner.stage_page_fn(self.inner.context, page);
    }

    fn read_page(
        context: *anyopaque,
        page_number: u32,
        destination: []u8,
    ) error{ApplyReadFailure}!void {
        const self: *RestoreIdentityGuard = @ptrCast(@alignCast(context));
        return self.inner.read_page_fn(
            self.inner.context,
            page_number,
            destination,
        );
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
        const self: *RestoreIdentityGuard = @ptrCast(@alignCast(context));
        return self.inner.publish_fn(self.inner.context, expected, verified);
    }

    fn abort(context: *anyopaque) void {
        const self: *RestoreIdentityGuard = @ptrCast(@alignCast(context));
        self.inner.abort_fn(self.inner.context);
    }
};

/// Caller-owned storage and state for one sequential restore. The job value
/// and every workspace plus the apply-backend context must stay at stable,
/// non-overlapping addresses while a restore runs.
pub const RestoreJob = struct {
    client: object.Client,
    codec_limits: ltx.Limits,
    apply_limits: ltx.ApplyLimits,
    backend: ltx.ApplyBackend,
    read_workspace: []u8,
    page_workspace: []u8,
    compressed_workspace: []u8,
    index_workspace: []ltx.PageIndexEntry,

    /// Applies the plan's files in order through private staging and atomic
    /// publication, returning the last verified post-apply position. A first
    /// snapshot replaces any existing target; every later transition must be
    /// contiguous. Each decoded header must match its planned object identity
    /// before the backend begins staging.
    pub fn run(self: *RestoreJob, plan: []const ltx.FileInfo) Error!ltx.Position {
        if (plan.len == 0) return error.TxNotAvailable;
        for (plan) |info| try validate_source_info(self.codec_limits, info);
        try self.validate_resource_aliases(plan);
        var restored_position: ?ltx.Position = null;
        for (plan, 0..) |info, index| {
            var source = try object.ObjectReader.init(
                self.client,
                info,
                self.read_workspace,
            );
            var identity_guard = RestoreIdentityGuard{
                .inner = self.backend,
                .expected = .{
                    .min_txid = info.min_txid,
                    .max_txid = info.max_txid,
                },
            };
            var applier = try ltx.StagedApplier.init(
                .v3,
                self.codec_limits,
                self.apply_limits,
                if (index == 0) .replace_snapshot else .contiguous,
                source.reader(),
                identity_guard.backend(),
                self.page_workspace,
                self.compressed_workspace,
                self.index_workspace,
            );
            const verified = applier.apply() catch |err| {
                if (identity_guard.mismatch) return error.ObjectIdentityMismatch;
                if (source.failure()) |storage_error| return storage_error;
                return err;
            };
            restored_position = verified.post_apply_position();
        }
        return restored_position.?;
    }

    fn validate_resource_aliases(
        self: *const RestoreJob,
        plan: []const ltx.FileInfo,
    ) Error!void {
        const controls = [_][]const u8{
            std.mem.asBytes(self),
            std.mem.sliceAsBytes(plan),
        };
        const workspaces = [_][]const u8{
            self.read_workspace,
            self.page_workspace,
            self.compressed_workspace,
            std.mem.sliceAsBytes(self.index_workspace),
            self.backend.backing_bytes orelse &.{},
        };
        if (ranges_overlap(&controls, &controls) or
            ranges_overlap(&workspaces, &workspaces) or
            ranges_overlap(&controls, &workspaces))
        {
            return error.WorkspaceAliasing;
        }
    }
};

// ── Compaction execution ──────────────────────────────────────────────────────

/// One bounded object-read window and decoder workspaces for a compaction
/// source. `object_reader` is initialized by `CompactionJob.run`.
pub const CompactionJobInput = struct {
    read_workspace: []u8,
    page_workspace: []u8,
    compressed_workspace: []u8,
    index_workspace: []ltx.PageIndexEntry,
    object_reader: object.ObjectReader = undefined,
};

/// Caller-owned storage and state for one level compaction. `inputs` and
/// `compaction_inputs` are parallel capacity arrays and must remain
/// address-stable while compaction runs.
pub const CompactionJob = struct {
    client: object.Client,
    codec_limits: ltx.Limits,
    compaction_limits: ltx.CompactionLimits,
    /// Per possible input: bounded object-read and decoder workspaces.
    inputs: []CompactionJobInput,
    /// Scratch compactor inputs, at least `inputs.len`.
    compaction_inputs: []ltx.CompactionInput,
    /// Whole-object fallback storage. May be empty when `client` supports
    /// transactional streaming write sessions.
    output_storage: []u8,
    output_compressed_workspace: []u8,
    output_compression_workspace: *ltx.LZ4CompressionWorkspace,
    output_index_workspace: []ltx.PageIndexEntry,

    /// Fetches the source objects, merges them through the codec compactor,
    /// and publishes one verified object at `destination_level`, streaming to
    /// private staging when the client supports it. Sources are decoded as
    /// current v3; objects this library writes always are.
    pub fn run(
        self: *CompactionJob,
        source: []const ltx.FileInfo,
        destination_level: u8,
    ) Error!ltx.VerifiedLTX {
        try self.validate_input_count(source.len);
        for (source) |info| try validate_source_info(self.codec_limits, info);
        const streams_output = self.client.supports_write_sessions();
        try self.validate_resource_aliases(source, streams_output);
        const identity = ltx.FileIdentity{
            .min_txid = source[0].min_txid,
            .max_txid = source[source.len - 1].max_txid,
        };
        if (streams_output) {
            const last_header = try self.read_last_header(
                source.len - 1,
                source[source.len - 1],
            );
            try self.initialize_inputs(source);
            return self.run_streaming(
                source.len,
                destination_level,
                identity,
                last_header.timestamp_ms,
            );
        }
        try self.initialize_inputs(source);
        return self.run_buffered(source.len, destination_level, identity);
    }

    fn validate_input_count(self: *const CompactionJob, input_count: usize) Error!void {
        if (input_count == 0) return error.CompactionNotAvailable;
        if (input_count > self.inputs.len or
            input_count > self.compaction_inputs.len)
        {
            return error.PlanCapacityExceeded;
        }
    }

    fn validate_resource_aliases(
        self: *const CompactionJob,
        source: []const ltx.FileInfo,
        streams_output: bool,
    ) Error!void {
        const controls = [_][]const u8{
            std.mem.asBytes(self),
            std.mem.sliceAsBytes(source),
            std.mem.sliceAsBytes(self.inputs[0..source.len]),
            std.mem.sliceAsBytes(self.compaction_inputs[0..source.len]),
        };
        const output = compaction_output_ranges(self, streams_output);
        if (ranges_overlap(&controls, &controls) or
            ranges_overlap(&output, &output) or
            ranges_overlap(&controls, &output))
        {
            return error.WorkspaceAliasing;
        }
        for (self.inputs[0..source.len], 0..) |input, index| {
            const ranges = compaction_job_input_ranges(input);
            if (ranges_overlap(&ranges, &ranges) or
                ranges_overlap(&controls, &ranges) or
                ranges_overlap(&output, &ranges))
            {
                return error.WorkspaceAliasing;
            }
            for (self.inputs[index + 1 .. source.len]) |later| {
                const later_ranges = compaction_job_input_ranges(later);
                if (ranges_overlap(&ranges, &later_ranges)) {
                    return error.WorkspaceAliasing;
                }
            }
        }
    }

    fn initialize_inputs(self: *CompactionJob, source: []const ltx.FileInfo) Error!void {
        for (source, self.inputs[0..source.len], self.compaction_inputs[0..source.len]) |
            info,
            *job_input,
            *compaction_input,
        | {
            job_input.object_reader = try object.ObjectReader.init(
                self.client,
                info,
                job_input.read_workspace,
            );
            compaction_input.* = ltx.CompactionInput.init(
                .v3,
                job_input.object_reader.reader(),
                job_input.page_workspace,
                job_input.compressed_workspace,
                job_input.index_workspace,
            );
        }
    }

    fn read_last_header(
        self: *CompactionJob,
        input_index: usize,
        info: ltx.FileInfo,
    ) Error!ltx.Header {
        const job_input = &self.inputs[input_index];
        var source = try object.ObjectReader.init(
            self.client,
            info,
            job_input.read_workspace,
        );
        var decoder = try ltx.Decoder.init(
            .v3,
            self.codec_limits,
            source.reader(),
            job_input.page_workspace,
            job_input.compressed_workspace,
            job_input.index_workspace,
        );
        const event = decoder.next() catch |err| {
            if (source.failure()) |storage_error| return storage_error;
            return err;
        };
        return switch (event) {
            .header => |header| header,
            else => error.InvalidState,
        };
    }

    fn run_streaming(
        self: *CompactionJob,
        input_count: usize,
        destination_level: u8,
        identity: ltx.FileIdentity,
        timestamp_ms: i64,
    ) Error!ltx.VerifiedLTX {
        var session = try self.client.begin_write(
            destination_level,
            identity,
            timestamp_ms,
        );
        errdefer session.abort();
        const verified = try self.compact(input_count, session.writer());
        try verify_identity(verified, identity);
        try session.finish();
        return verified;
    }

    fn run_buffered(
        self: *CompactionJob,
        input_count: usize,
        destination_level: u8,
        identity: ltx.FileIdentity,
    ) Error!ltx.VerifiedLTX {
        var sink = ltx.SliceWriter.init(self.output_storage);
        const verified = try self.compact(input_count, sink.writer());
        try verify_identity(verified, identity);
        try self.client.write(
            destination_level,
            identity,
            verified.header.timestamp_ms,
            sink.written(),
        );
        return verified;
    }

    fn compact(
        self: *CompactionJob,
        input_count: usize,
        writer: ltx.Writer,
    ) Error!ltx.VerifiedLTX {
        var compactor = try ltx.Compactor.init(
            .v3,
            self.codec_limits,
            self.compaction_limits,
            self.compaction_inputs[0..input_count],
            writer,
            self.output_compressed_workspace,
            self.output_compression_workspace,
            self.output_index_workspace,
        );
        return compactor.compact() catch |err| {
            for (self.inputs[0..input_count]) |*input| {
                if (input.object_reader.failure()) |storage_error| {
                    return storage_error;
                }
            }
            return err;
        };
    }
};

fn validate_source_info(limits: ltx.Limits, info: ltx.FileInfo) Error!void {
    if (info.level > ltx.max_level) return error.InvalidLevel;
    if (info.min_txid.value > info.max_txid.value) return error.InvalidIdentity;
    if (info.size_bytes == 0) return error.InvalidReadRange;
    if (info.size_bytes > limits.max_input_bytes) return error.InputLimitExceeded;
}

fn compaction_job_input_ranges(input: CompactionJobInput) [4][]const u8 {
    return .{
        input.read_workspace,
        input.page_workspace,
        input.compressed_workspace,
        std.mem.sliceAsBytes(input.index_workspace),
    };
}

fn compaction_output_ranges(
    job: *const CompactionJob,
    streams_output: bool,
) [4][]const u8 {
    return .{
        if (streams_output) job.output_storage[0..0] else job.output_storage,
        job.output_compressed_workspace,
        std.mem.asBytes(job.output_compression_workspace),
        std.mem.sliceAsBytes(job.output_index_workspace),
    };
}

fn ranges_overlap(left: []const []const u8, right: []const []const u8) bool {
    for (left, 0..) |left_range, left_index| {
        for (right, 0..) |right_range, right_index| {
            if (left.ptr == right.ptr and left_index == right_index) continue;
            if (slices_overlap(left_range, right_range)) return true;
        }
    }
    return false;
}

fn slices_overlap(left: []const u8, right: []const u8) bool {
    if (left.len == 0 or right.len == 0) return false;
    const left_start = @intFromPtr(left.ptr);
    const right_start = @intFromPtr(right.ptr);
    const left_end = std.math.add(usize, left_start, left.len) catch return true;
    const right_end = std.math.add(usize, right_start, right.len) catch return true;
    return left_start < right_end and right_start < left_end;
}

fn verify_identity(verified: ltx.VerifiedLTX, expected: ltx.FileIdentity) Error!void {
    if (verified.header.min_txid.value != expected.min_txid.value or
        verified.header.max_txid.value != expected.max_txid.value)
    {
        return error.ObjectIdentityMismatch;
    }
}

// ── Pure planner tests ────────────────────────────────────────────────────────

const testing = std.testing;

test "default ladder matches litestream v0.5.16 and validates ordering" {
    const ladder = CompactionLevels{ .levels = &default_levels };
    try ladder.validate();
    try testing.expectEqual(@as(u8, 3), ladder.max_level());
    try testing.expectEqual(@as(u64, 30_000), try ladder.interval_ms(1));
    try testing.expectEqual(@as(u64, 300_000), try ladder.interval_ms(2));
    try testing.expectEqual(@as(u64, 3_600_000), try ladder.interval_ms(3));
    try testing.expectEqual(@as(?u8, 3), ladder.previous_level(ltx.snapshot_level));
    try testing.expectEqual(@as(?u8, ltx.snapshot_level), ladder.next_level(3));
    try testing.expectEqual(@as(?u8, null), ladder.next_level(ltx.snapshot_level));
    try testing.expectEqual(@as(?u8, null), ladder.previous_level(0));

    try testing.expectError(error.InvalidLevels, (CompactionLevels{
        .levels = &.{.{ .level = 1, .interval_ms = 0 }},
    }).validate());
    try testing.expectError(error.InvalidLevels, (CompactionLevels{
        .levels = &.{.{ .level = 0, .interval_ms = 1 }},
    }).validate());
    try testing.expectError(error.InvalidLevels, (CompactionLevels{ .levels = &.{} }).validate());
}

test "interval boundaries truncate to the interval like litestream" {
    const ladder = CompactionLevels{ .levels = &default_levels };
    try testing.expectEqual(
        @as(u64, 90_000),
        try ladder.previous_compaction_at_ms(1, 95_000),
    );
    try testing.expectEqual(
        @as(u64, 120_000),
        try ladder.next_compaction_at_ms(1, 95_000),
    );
    try testing.expectEqual(
        @as(u64, 95_000),
        try ladder.previous_compaction_at_ms(0, 95_000),
    );
}

fn file_info(level: u8, min: u64, max: u64) ltx.FileInfo {
    return .{
        .level = level,
        .min_txid = ltx.TXID.init(min),
        .max_txid = ltx.TXID.init(max),
        .size_bytes = 100,
    };
}

fn empty_level_lists() [ltx.snapshot_level + 1][]const ltx.FileInfo {
    var lists: [ltx.snapshot_level + 1][]const ltx.FileInfo = undefined;
    for (&lists) |*list| list.* = &.{};
    return lists;
}

test "restore plan follows a contiguous L0 chain and honors targets" {
    var lists = empty_level_lists();
    lists[0] = &.{
        file_info(0, 1, 1),
        file_info(0, 2, 2),
        file_info(0, 3, 3),
    };
    var destination: [8]ltx.FileInfo = undefined;
    const plan = try calc_restore_plan(&lists, ltx.TXID.init(0), &destination);
    try testing.expectEqual(@as(usize, 3), plan.len);
    try testing.expectEqual(@as(u64, 1), plan[0].min_txid.value);
    try testing.expectEqual(@as(u64, 3), plan[2].max_txid.value);

    const capped = try calc_restore_plan(&lists, ltx.TXID.init(2), &destination);
    try testing.expectEqual(@as(usize, 2), capped.len);
    try testing.expectEqual(@as(u64, 2), capped[1].max_txid.value);

    try testing.expectError(
        error.TxNotAvailable,
        calc_restore_plan(&lists, ltx.TXID.init(9), &destination),
    );
    try testing.expectError(
        error.TxNotAvailable,
        calc_restore_plan(&empty_level_lists(), ltx.TXID.init(0), &destination),
    );
}

test "restore plan prefers the higher level and rejects tail gaps" {
    var lists = empty_level_lists();
    lists[0] = &.{
        file_info(0, 1, 1),
        file_info(0, 2, 2),
        file_info(0, 3, 3),
    };
    lists[1] = &.{file_info(1, 1, 2)};
    var destination: [8]ltx.FileInfo = undefined;
    const plan = try calc_restore_plan(&lists, ltx.TXID.init(0), &destination);
    // The L1 file covers 1-2, then the L0 chain continues at 3.
    try testing.expectEqual(@as(usize, 2), plan.len);
    try testing.expectEqual(@as(u8, 1), plan[0].level);
    try testing.expectEqual(@as(u64, 3), plan[1].max_txid.value);

    lists[0] = &.{
        file_info(0, 1, 1),
        file_info(0, 2, 2),
        file_info(0, 4, 4),
    };
    try testing.expectError(
        error.NonContiguousPlan,
        calc_restore_plan(&lists, ltx.TXID.init(0), &destination),
    );
    // A targeted restore ignores the tail beyond its goal.
    const targeted = try calc_restore_plan(&lists, ltx.TXID.init(2), &destination);
    try testing.expectEqual(@as(usize, 1), targeted.len);
    try testing.expectEqual(@as(u8, 1), targeted[0].level);
}

test "restore plan anchors on the newest qualifying snapshot" {
    var lists = empty_level_lists();
    lists[0] = &.{file_info(0, 4, 4)};
    lists[ltx.snapshot_level] = &.{
        file_info(ltx.snapshot_level, 1, 1),
        file_info(ltx.snapshot_level, 1, 3),
    };
    var destination: [8]ltx.FileInfo = undefined;
    const plan = try calc_restore_plan(&lists, ltx.TXID.init(0), &destination);
    try testing.expectEqual(@as(usize, 2), plan.len);
    try testing.expectEqual(@as(u64, 3), plan[0].max_txid.value);
    try testing.expectEqual(ltx.snapshot_level, plan[0].level);

    const capped = try calc_restore_plan(&lists, ltx.TXID.init(1), &destination);
    try testing.expectEqual(@as(usize, 1), capped.len);
    try testing.expectEqual(@as(u64, 1), capped[0].max_txid.value);
}

test "compaction planning continues the destination and bounds the prefix" {
    const source = [_]ltx.FileInfo{ file_info(0, 1, 1), file_info(0, 2, 2) };

    const fresh = try plan_compaction(&source, &.{}, 4, 1000);
    try testing.expectEqual(@as(usize, 2), fresh.input_count);
    try testing.expectEqual(@as(u64, 1), fresh.seek_txid.value);

    // The destination already holds TXID 2, so this source does not continue
    // it from TXID 3.
    const held = [_]ltx.FileInfo{file_info(1, 1, 2)};
    try testing.expectError(
        error.CompactionNotAvailable,
        plan_compaction(&source, &held, 4, 1000),
    );
    const continuing = [_]ltx.FileInfo{ file_info(0, 3, 3), file_info(0, 4, 4) };
    const resumed = try plan_compaction(&continuing, &held, 4, 1000);
    try testing.expectEqual(@as(usize, 2), resumed.input_count);
    try testing.expectEqual(@as(u64, 3), resumed.seek_txid.value);

    const bounded = try plan_compaction(&source, &.{}, 1, 1000);
    try testing.expectEqual(@as(usize, 1), bounded.input_count);
    const byte_bounded = try plan_compaction(&source, &.{}, 4, 150);
    try testing.expectEqual(@as(usize, 1), byte_bounded.input_count);
    var overflowing = source;
    overflowing[0].size_bytes = std.math.maxInt(u64);
    overflowing[1].size_bytes = 1;
    try testing.expectError(
        error.CompactionNotAvailable,
        plan_compaction(&overflowing, &.{}, 4, std.math.maxInt(u64)),
    );
    const empty = try plan_compaction(&.{}, &.{}, 4, 1000);
    try testing.expectEqual(@as(usize, 0), empty.input_count);
}

test "retention planning keeps only absorbed ranges" {
    const lower = [_]ltx.FileInfo{
        file_info(0, 1, 1),
        file_info(0, 2, 2),
        file_info(0, 3, 3),
        file_info(0, 5, 5),
    };
    const upper = [_]ltx.FileInfo{file_info(1, 1, 3)};
    var destination: [4]ltx.FileInfo = undefined;
    const deletable = plan_retention(&lower, &upper, &destination);
    try testing.expectEqual(@as(usize, 3), deletable.len);
    try testing.expectEqual(@as(u64, 1), deletable[0].min_txid.value);
    try testing.expectEqual(@as(u64, 3), deletable[2].max_txid.value);
}
