//! Synchronous per-database replication orchestration.
//!
//! `Controller` owns one `ltx_capture.Session` and hides level listing,
//! restore planning and execution, adjacent-level compaction, and safe
//! retention. The host still owns scheduling, concurrency, fencing, and
//! acknowledgement policy. Every variable-size resource is caller-owned and
//! validated before the SQLite session opens.

const std = @import("std");
const ltx = @import("ltx");
const wal = @import("ltx_wal");
const object = @import("ltx_object");
const replica = @import("ltx_replica");
const capture = @import("ltx_capture");
const resource_model = @import("ltx_resources");

const level_count = @as(usize, ltx.snapshot_level) + 1;

pub const Error = error{
    InvalidConfiguration,
    InvalidResources,
    InvalidListing,
    InvalidDestinationLevel,
    ObjectTreeNotEmpty,
    RestoreTargetNotQuiescent,
    TimestampRegression,
    Poisoned,
    Finished,
} || ltx.Error || wal.Error || object.Error || replica.Error || capture.Error;

pub const Startup = union(enum) {
    /// Proves every level is empty before opening the capture session.
    require_empty,
    /// Host-verified local image position, commonly protected by an epoch.
    verified_local: ltx.Position,
    /// Restores the latest verified object chain to a sidecar-free,
    /// host-quiesced `database_name`, then opens capture and seeds it.
    restore_latest,
};

pub const Config = struct {
    codec_limits: ltx.Limits,
    wal_limits: wal.Limits,
    apply_limits: ltx.ApplyLimits,
    compaction_limits: ltx.CompactionLimits,
    levels: replica.CompactionLevels,
    max_files_per_level: u32,
    max_restore_files: u32,
    max_compaction_input_bytes: u64,
    /// Capacity of each sequential object-read window used by restore and
    /// compaction, independently of the maximum accepted object size.
    read_workspace_bytes: u32,
    checkpoint_threshold_bytes: u64 = 0,
    checkpoint_interval_ms: u64 = 0,
    checkpoint_max_frames: u32 = 0,
};

const max_compaction_levels = @as(usize, ltx.snapshot_level);

const StableConfig = struct {
    codec_limits: ltx.Limits,
    wal_limits: wal.Limits,
    apply_limits: ltx.ApplyLimits,
    compaction_limits: ltx.CompactionLimits,
    levels: [max_compaction_levels]replica.CompactionLevel,
    level_count: u8,
    max_files_per_level: u32,
    max_restore_files: u32,
    max_compaction_input_bytes: u64,
    checkpoint_threshold_bytes: u64,
    checkpoint_interval_ms: u64,
    checkpoint_max_frames: u32,

    fn copy(config: Config) StableConfig {
        var stable = StableConfig{
            .codec_limits = config.codec_limits,
            .wal_limits = config.wal_limits,
            .apply_limits = config.apply_limits,
            .compaction_limits = config.compaction_limits,
            .levels = undefined,
            .level_count = @intCast(config.levels.levels.len),
            .max_files_per_level = config.max_files_per_level,
            .max_restore_files = config.max_restore_files,
            .max_compaction_input_bytes = config.max_compaction_input_bytes,
            .checkpoint_threshold_bytes = config.checkpoint_threshold_bytes,
            .checkpoint_interval_ms = config.checkpoint_interval_ms,
            .checkpoint_max_frames = config.checkpoint_max_frames,
        };
        @memcpy(stable.levels[0..config.levels.levels.len], config.levels.levels);
        return stable;
    }

    fn contains_level(self: *const StableConfig, level: u8) bool {
        return level == ltx.snapshot_level or level < self.level_count;
    }

    fn previous_level(self: *const StableConfig, level: u8) ?u8 {
        if (level == ltx.snapshot_level) return self.level_count - 1;
        if (level == 0 or level >= self.level_count) return null;
        return level - 1;
    }
};

pub const Options = struct {
    dir: std.Io.Dir,
    io: std.Io,
    database_name: []const u8,
    client: object.Client,
    config: Config,
    startup: Startup,
};

/// All variable-size storage for one controller. The value, its slices, and
/// the pointed-to object-client context must remain stable until `finish()`.
pub const Resources = struct {
    capture: capture.Workspaces,
    /// `level_count * Config.max_files_per_level` entries, flattened by level.
    level_listings: []ltx.FileInfo,
    restore_plan: []ltx.FileInfo,
    retention_plan: []ltx.FileInfo,
    restore_read_workspace: []u8,
    restore_page_workspace: []u8,
    restore_compressed_workspace: []u8,
    restore_index_workspace: []ltx.PageIndexEntry,
    compaction_job_inputs: []replica.CompactionJobInput,
    compaction_inputs: []ltx.CompactionInput,
    /// Whole-object fallback; may be empty when `Options.client` supports
    /// transactional write sessions.
    compaction_output_storage: []u8,
    compaction_output_compressed_workspace: []u8,
    compaction_output_compression_workspace: *ltx.LZ4CompressionWorkspace,
    compaction_output_index_workspace: []ltx.PageIndexEntry,
};

pub const SyncReport = struct {
    position: ltx.Position,
    page_count: u32,
};

pub const SyncResult = union(enum) {
    unchanged,
    published: SyncReport,
};

pub const RestoreReport = struct {
    position: ltx.Position,
    file_count: u32,
};

pub const MaintenanceReport = struct {
    destination_level: u8,
    identity: ltx.FileIdentity,
    input_file_count: u32,
    deleted_file_count: u64,
    page_count: u32,
};

pub const MaintenanceResult = union(enum) {
    idle,
    compacted: MaintenanceReport,
};

const State = enum {
    initializing,
    ready,
    running,
    poisoned,
    finished,
};

const Capacities = struct {
    max_output_bytes: usize,
    read_workspace_bytes: usize,
    max_page_bytes: usize,
    max_compressed_bytes: usize,
    max_index_entries: usize,
    max_wal_bytes: usize,
    max_wal_pages: usize,
    max_files_per_level: usize,
    max_restore_files: usize,
    max_compaction_inputs: usize,
    listing_entries: usize,
};

/// One synchronous, single-owner controller. Do not copy it after `init`.
pub const Controller = struct {
    session: capture.Session,
    client: object.Client,
    config: StableConfig,
    resources: *Resources,
    level_lists: [level_count][]const ltx.FileInfo = @splat(&.{}),
    last_sync_timestamp_ms: ?i64 = null,
    state: State = .initializing,

    pub fn init(options: Options, resources: *Resources) Error!Controller {
        const capacities = try validate_configuration(options);
        try validate_resources(
            resources,
            capacities,
            options.client.supports_write_sessions(),
        );
        var self = Controller{
            .session = undefined,
            .client = options.client,
            .config = StableConfig.copy(options.config),
            .resources = resources,
        };
        const seed = try self.prepare_startup(options);
        self.session = try capture.Session.init(
            options.dir,
            options.io,
            options.database_name,
            options.config.codec_limits,
            options.config.wal_limits,
            options.client,
        );
        errdefer self.session.finish();
        set_checkpoint_policy(&self.session, &self.config);
        if (seed) |position_value| try self.session.seed_position(position_value);
        self.state = .ready;
        return self;
    }

    pub fn sync(self: *Controller, timestamp_ms: i64) Error!SyncResult {
        try self.require_ready();
        try self.validate_sync_timestamp(timestamp_ms);
        try self.begin_operation();
        const result = self.sync_internal(timestamp_ms) catch |err| {
            self.poison();
            return err;
        };
        self.state = .ready;
        return result;
    }

    /// The backend target must be distinct from this controller's live
    /// database and quiesced by the host for the entire restore.
    pub fn restore(
        self: *Controller,
        target_txid: ltx.TXID,
        backend: ltx.ApplyBackend,
    ) Error!RestoreReport {
        try self.begin_operation();
        const report = self.restore_internal(target_txid, backend) catch |err| {
            switch (err) {
                error.TxNotAvailable => self.state = .ready,
                else => self.poison(),
            }
            return err;
        };
        self.state = .ready;
        return report;
    }

    pub fn maintain(
        self: *Controller,
        destination_level: u8,
    ) Error!MaintenanceResult {
        try self.require_ready();
        _ = try self.source_level(destination_level);
        try self.begin_operation();
        const report = self.maintain_internal(destination_level) catch |err| {
            self.poison();
            return err;
        };
        self.state = .ready;
        return report;
    }

    pub fn position(self: *const Controller) Error!ltx.Position {
        return switch (self.state) {
            .ready => self.session.position,
            .poisoned => error.Poisoned,
            .finished => error.Finished,
            .initializing, .running => error.InvalidState,
        };
    }

    pub fn finish(self: *Controller) void {
        std.debug.assert(self.state != .initializing and self.state != .running);
        if (self.state == .finished) return;
        self.session.finish();
        self.state = .finished;
    }

    fn prepare_startup(self: *Controller, options: Options) Error!?ltx.Position {
        return switch (options.startup) {
            .require_empty => blk: {
                try self.list_all_levels();
                for (self.level_lists) |listed| {
                    if (listed.len != 0) return error.ObjectTreeNotEmpty;
                }
                break :blk null;
            },
            .verified_local => |position_value| position_value,
            .restore_latest => blk: {
                try reject_restore_sidecars(options);
                var backend = try replica.RestoreBackend.init(
                    options.dir,
                    options.io,
                    options.database_name,
                );
                const report = try self.restore_internal(
                    ltx.TXID.init(0),
                    backend.backend(),
                );
                break :blk report.position;
            },
        };
    }

    fn sync_internal(self: *Controller, timestamp_ms: i64) Error!SyncResult {
        const page_count = self.session.sync(
            &self.resources.capture,
            timestamp_ms,
        ) catch |err| switch (err) {
            error.CaptureUnchanged => {
                self.last_sync_timestamp_ms = timestamp_ms;
                return .unchanged;
            },
            else => return err,
        };
        self.last_sync_timestamp_ms = timestamp_ms;
        return .{ .published = .{
            .position = self.session.position,
            .page_count = page_count,
        } };
    }

    fn restore_internal(
        self: *Controller,
        target_txid: ltx.TXID,
        backend: ltx.ApplyBackend,
    ) Error!RestoreReport {
        try self.list_all_levels();
        const plan = try replica.calc_restore_plan(
            &self.level_lists,
            target_txid,
            self.resources.restore_plan[0..self.config.max_restore_files],
        );
        var job = replica.RestoreJob{
            .client = self.client,
            .codec_limits = self.config.codec_limits,
            .apply_limits = self.config.apply_limits,
            .backend = backend,
            .read_workspace = self.resources.restore_read_workspace,
            .page_workspace = self.resources.restore_page_workspace,
            .compressed_workspace = self.resources.restore_compressed_workspace,
            .index_workspace = self.resources.restore_index_workspace,
        };
        const restored = try job.run(plan);
        const count = std.math.cast(u32, plan.len) orelse
            return error.PlanCapacityExceeded;
        return .{ .position = restored, .file_count = count };
    }

    fn maintain_internal(self: *Controller, destination_level: u8) Error!MaintenanceResult {
        const source_level_value = try self.source_level(destination_level);
        try self.list_all_levels();
        const coverage_txid = try self.upper_coverage_txid(destination_level);
        const source = source_after(self.level_lists[source_level_value], coverage_txid);
        if (source.len == 0) return .idle;
        const snapshot = if (destination_level == ltx.snapshot_level)
            newest_snapshot(self.level_lists[ltx.snapshot_level])
        else
            null;
        const budget = try self.compaction_budget(snapshot);
        if (budget.max_source_inputs == 0 or budget.max_source_bytes == 0) {
            return .idle;
        }
        var anchor: [1]ltx.FileInfo = undefined;
        const upper = make_anchor(coverage_txid, &anchor);
        const plan = try replica.plan_compaction(
            source,
            upper,
            budget.max_source_inputs,
            budget.max_source_bytes,
        );
        if (plan.input_count == 0) return .idle;
        return self.execute_compaction(
            destination_level,
            source[0..plan.input_count],
            snapshot,
        );
    }

    fn execute_compaction(
        self: *Controller,
        destination_level: u8,
        source: []const ltx.FileInfo,
        snapshot: ?ltx.FileInfo,
    ) Error!MaintenanceResult {
        var count: usize = 0;
        if (snapshot) |info| {
            self.resources.restore_plan[0] = info;
            count = 1;
        }
        @memcpy(self.resources.restore_plan[count..][0..source.len], source);
        count += source.len;
        var job = self.compaction_job();
        const verified = try job.run(
            self.resources.restore_plan[0..count],
            destination_level,
        );
        const output = file_info_from_verified(destination_level, verified);
        var deleted = try self.delete_compacted_source(source, output);
        if (snapshot != null) {
            const old_deleted = try self.delete_covered_snapshots(output);
            deleted = std.math.add(u64, deleted, old_deleted) catch
                return error.PlanCapacityExceeded;
        }
        return .{ .compacted = make_maintenance_report(
            destination_level,
            verified,
            count,
            deleted,
        ) };
    }

    fn compaction_job(self: *Controller) replica.CompactionJob {
        return .{
            .client = self.client,
            .codec_limits = self.config.codec_limits,
            .compaction_limits = self.config.compaction_limits,
            .inputs = self.resources.compaction_job_inputs,
            .compaction_inputs = self.resources.compaction_inputs,
            .output_storage = self.resources.compaction_output_storage,
            .output_compressed_workspace = self.resources.compaction_output_compressed_workspace,
            .output_compression_workspace = self.resources.compaction_output_compression_workspace,
            .output_index_workspace = self.resources.compaction_output_index_workspace,
        };
    }

    fn list_all_levels(self: *Controller) Error!void {
        const files_per_level: usize = @intCast(self.config.max_files_per_level);
        for (0..level_count) |level| {
            const start = level * files_per_level;
            const destination = self.resources.level_listings[start..][0..files_per_level];
            const listed = try self.client.list(
                @intCast(level),
                ltx.TXID.init(0),
                destination,
            );
            try self.validate_listing(@intCast(level), listed);
            self.level_lists[level] = listed;
        }
    }

    fn validate_listing(
        self: *const Controller,
        level: u8,
        listed: []const ltx.FileInfo,
    ) Error!void {
        var previous: ?ltx.FileInfo = null;
        for (listed) |info| {
            if (info.level != level or info.min_txid.value == 0 or
                info.min_txid.value > info.max_txid.value or
                info.size_bytes == 0 or
                info.size_bytes > self.config.codec_limits.max_input_bytes)
            {
                return error.InvalidListing;
            }
            if (level == ltx.snapshot_level and info.min_txid.value != 1) {
                return error.InvalidListing;
            }
            if (previous) |prior| {
                const ascending = prior.min_txid.value < info.min_txid.value or
                    (prior.min_txid.value == info.min_txid.value and
                        prior.max_txid.value < info.max_txid.value);
                if (!ascending) return error.InvalidListing;
            }
            previous = info;
        }
    }

    fn upper_coverage_txid(
        self: *Controller,
        destination_level: u8,
    ) Error!ltx.TXID {
        var upper_lists: [level_count][]const ltx.FileInfo = @splat(&.{});
        for (destination_level..level_count) |level| {
            upper_lists[level] = self.level_lists[level];
        }
        const plan = replica.calc_restore_plan(
            &upper_lists,
            ltx.TXID.init(0),
            self.resources.restore_plan[0..self.config.max_restore_files],
        ) catch |err| switch (err) {
            error.TxNotAvailable => return ltx.TXID.init(0),
            else => return err,
        };
        return plan[plan.len - 1].max_txid;
    }

    fn source_level(self: *const Controller, destination_level: u8) Error!u8 {
        if (destination_level == 0 or
            !self.config.contains_level(destination_level))
        {
            return error.InvalidDestinationLevel;
        }
        return self.config.previous_level(destination_level) orelse
            error.InvalidDestinationLevel;
    }

    const CompactionBudget = struct {
        max_source_inputs: usize,
        max_source_bytes: u64,
    };

    fn compaction_budget(
        self: *const Controller,
        snapshot: ?ltx.FileInfo,
    ) Error!CompactionBudget {
        var input_count: usize = @intCast(self.config.compaction_limits.max_inputs);
        var input_bytes = self.config.max_compaction_input_bytes;
        if (snapshot) |info| {
            if (input_count == 0 or info.size_bytes >= input_bytes) {
                return .{ .max_source_inputs = 0, .max_source_bytes = 0 };
            }
            input_count -= 1;
            input_bytes -= info.size_bytes;
        }
        return .{
            .max_source_inputs = input_count,
            .max_source_bytes = input_bytes,
        };
    }

    fn delete_compacted_source(
        self: *Controller,
        source: []const ltx.FileInfo,
        output: ltx.FileInfo,
    ) Error!u64 {
        var count: usize = 0;
        for (source) |info| {
            if (!contains(output, info)) return error.ObjectIdentityMismatch;
            self.resources.retention_plan[count] = info;
            count += 1;
        }
        if (count != 0) try self.client.delete(self.resources.retention_plan[0..count]);
        return count;
    }

    fn delete_covered_snapshots(
        self: *Controller,
        output: ltx.FileInfo,
    ) Error!u64 {
        var count: usize = 0;
        for (self.level_lists[ltx.snapshot_level]) |info| {
            if (!same_identity(info, output) and contains(output, info)) {
                self.resources.retention_plan[count] = info;
                count += 1;
            }
        }
        if (count != 0) try self.client.delete(self.resources.retention_plan[0..count]);
        return count;
    }

    fn begin_operation(self: *Controller) Error!void {
        try self.require_ready();
        self.state = .running;
    }

    fn require_ready(self: *const Controller) Error!void {
        switch (self.state) {
            .ready => {},
            .poisoned => return error.Poisoned,
            .finished => return error.Finished,
            .initializing, .running => return error.InvalidState,
        }
    }

    fn validate_sync_timestamp(self: *const Controller, timestamp_ms: i64) Error!void {
        if (timestamp_ms < 0) return error.InvalidTimestamp;
        if (self.last_sync_timestamp_ms) |previous| {
            if (timestamp_ms < previous) return error.TimestampRegression;
        }
    }

    fn poison(self: *Controller) void {
        std.debug.assert(self.state == .running);
        self.state = .poisoned;
    }
};

fn validate_configuration(options: Options) Error!Capacities {
    if (options.database_name.len == 0) return error.InvalidConfiguration;
    options.config.codec_limits.validate() catch return error.InvalidConfiguration;
    options.config.wal_limits.validate() catch return error.InvalidConfiguration;
    options.config.apply_limits.validate() catch return error.InvalidConfiguration;
    options.config.compaction_limits.validate() catch return error.InvalidConfiguration;
    options.config.levels.validate() catch return error.InvalidConfiguration;
    _ = resource_model.encoder_workspace_bytes(options.config.codec_limits) catch
        return error.InvalidConfiguration;
    if (options.config.max_files_per_level == 0 or
        options.config.max_restore_files == 0 or
        options.config.max_compaction_input_bytes == 0 or
        options.config.read_workspace_bytes == 0 or
        options.config.read_workspace_bytes >
            options.config.codec_limits.max_input_bytes or
        options.config.codec_limits.max_output_bytes >
            options.config.codec_limits.max_input_bytes or
        options.config.max_restore_files < options.config.compaction_limits.max_inputs)
    {
        return error.InvalidConfiguration;
    }
    return calculate_capacities(options.config) catch return error.InvalidConfiguration;
}

fn reject_restore_sidecars(options: Options) Error!void {
    const suffixes = [_][]const u8{ "-wal", "-shm", "-journal" };
    for (suffixes) |suffix| {
        if (options.database_name.len > std.Io.Dir.max_path_bytes - suffix.len) {
            return error.InvalidConfiguration;
        }
        var path: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const length = options.database_name.len + suffix.len;
        @memcpy(path[0..options.database_name.len], options.database_name);
        @memcpy(path[options.database_name.len..length], suffix);
        _ = options.dir.statFile(
            options.io,
            path[0..length],
            .{},
        ) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return error.StorageFailure,
        };
        return error.RestoreTargetNotQuiescent;
    }
}

fn calculate_capacities(config: Config) !Capacities {
    const max_output: usize = try cast_usize(config.codec_limits.max_output_bytes);
    const read_workspace: usize = try cast_usize(config.read_workspace_bytes);
    const max_page: usize = try cast_usize(config.codec_limits.max_page_size);
    const max_compressed: usize = try cast_usize(
        config.codec_limits.max_compressed_page_size,
    );
    const max_index: usize = try cast_usize(config.codec_limits.max_page_index_entries);
    const max_wal_pages: usize = try cast_usize(config.wal_limits.max_pages);
    const frame_bytes = try add_usize(
        wal.frame_header_size_bytes,
        try cast_usize(config.wal_limits.max_page_size),
    );
    const max_wal = try add_usize(
        wal.header_size_bytes,
        try mul_usize(try cast_usize(config.wal_limits.max_frames), frame_bytes),
    );
    const files: usize = try cast_usize(config.max_files_per_level);
    return .{
        .max_output_bytes = max_output,
        .read_workspace_bytes = read_workspace,
        .max_page_bytes = max_page,
        .max_compressed_bytes = max_compressed,
        .max_index_entries = max_index,
        .max_wal_bytes = max_wal,
        .max_wal_pages = max_wal_pages,
        .max_files_per_level = files,
        .max_restore_files = try cast_usize(config.max_restore_files),
        .max_compaction_inputs = try cast_usize(config.compaction_limits.max_inputs),
        .listing_entries = try mul_usize(level_count, files),
    };
}

fn validate_resources(
    resources: *const Resources,
    capacities: Capacities,
    streams_output: bool,
) Error!void {
    try validate_control_lengths(resources, capacities);
    try validate_control_aliases(resources, capacities);
    try validate_capture_resources(resources, capacities, streams_output);
    try validate_restore_resources(resources, capacities);
    try validate_compaction_resources(resources, capacities, streams_output);
}

fn validate_control_lengths(
    resources: *const Resources,
    capacities: Capacities,
) Error!void {
    if (resources.level_listings.len < capacities.listing_entries or
        resources.restore_plan.len < capacities.max_restore_files or
        resources.retention_plan.len < capacities.max_files_per_level or
        resources.compaction_job_inputs.len < capacities.max_compaction_inputs or
        resources.compaction_inputs.len < capacities.max_compaction_inputs)
    {
        return error.InvalidResources;
    }
}

fn validate_control_aliases(
    resources: *const Resources,
    capacities: Capacities,
) Error!void {
    const ranges = [_][]const u8{
        std.mem.asBytes(resources),
        std.mem.sliceAsBytes(resources.level_listings[0..capacities.listing_entries]),
        std.mem.sliceAsBytes(resources.restore_plan[0..capacities.max_restore_files]),
        std.mem.sliceAsBytes(resources.retention_plan[0..capacities.max_files_per_level]),
        std.mem.sliceAsBytes(
            resources.compaction_job_inputs[0..capacities.max_compaction_inputs],
        ),
        std.mem.sliceAsBytes(
            resources.compaction_inputs[0..capacities.max_compaction_inputs],
        ),
    };
    try validate_disjoint(&ranges);
}

fn validate_capture_resources(
    all_resources: *const Resources,
    capacities: Capacities,
    streams_output: bool,
) Error!void {
    const resources = all_resources.capture;
    const bitmap_bytes = try add_usize(capacities.max_wal_pages, 7) / 8;
    if (resources.wal_storage.len < capacities.max_wal_bytes or
        resources.map_slots.len < capacities.max_wal_pages or
        resources.map_pending.len < capacities.max_wal_pages or
        resources.map_seen.len < bitmap_bytes or
        resources.map_entries.len < capacities.max_wal_pages or
        (!streams_output and resources.output_storage.len < capacities.max_output_bytes) or
        resources.page_workspace.len < capacities.max_page_bytes or
        resources.compressed_workspace.len < capacities.max_compressed_bytes or
        resources.index_workspace.len < capacities.max_index_entries)
    {
        return error.InvalidResources;
    }
    const ranges = [_][]const u8{
        std.mem.asBytes(all_resources),
        std.mem.sliceAsBytes(
            all_resources.compaction_job_inputs[0..capacities.max_compaction_inputs],
        ),
        resources.wal_storage,
        std.mem.sliceAsBytes(resources.map_slots),
        std.mem.sliceAsBytes(resources.map_pending),
        resources.map_seen,
        std.mem.sliceAsBytes(resources.map_entries),
        if (streams_output) resources.output_storage[0..0] else resources.output_storage,
        resources.page_workspace,
        resources.compressed_workspace,
        std.mem.asBytes(resources.compression_workspace),
        std.mem.sliceAsBytes(resources.index_workspace),
    };
    try validate_disjoint(&ranges);
}

fn validate_restore_resources(
    resources: *const Resources,
    capacities: Capacities,
) Error!void {
    if (resources.restore_read_workspace.len < capacities.read_workspace_bytes or
        resources.restore_page_workspace.len < capacities.max_page_bytes or
        resources.restore_compressed_workspace.len < capacities.max_compressed_bytes or
        resources.restore_index_workspace.len < capacities.max_index_entries)
    {
        return error.InvalidResources;
    }
    const workspaces = [_][]const u8{
        resources.restore_read_workspace,
        resources.restore_page_workspace,
        resources.restore_compressed_workspace,
        std.mem.sliceAsBytes(resources.restore_index_workspace),
    };
    const controls = [_][]const u8{
        std.mem.asBytes(resources),
        std.mem.sliceAsBytes(resources.level_listings[0..capacities.listing_entries]),
        std.mem.sliceAsBytes(resources.restore_plan[0..capacities.max_restore_files]),
        std.mem.sliceAsBytes(
            resources.compaction_job_inputs[0..capacities.max_compaction_inputs],
        ),
    };
    try validate_disjoint(&workspaces);
    try validate_disjoint_groups(&controls, &workspaces);
}

fn validate_compaction_resources(
    resources: *const Resources,
    capacities: Capacities,
    streams_output: bool,
) Error!void {
    if ((!streams_output and
        resources.compaction_output_storage.len < capacities.max_output_bytes) or
        resources.compaction_output_compressed_workspace.len <
            capacities.max_compressed_bytes or
        resources.compaction_output_index_workspace.len < capacities.max_index_entries)
    {
        return error.InvalidResources;
    }
    for (resources.compaction_job_inputs[0..capacities.max_compaction_inputs]) |input| {
        if (input.read_workspace.len < capacities.read_workspace_bytes or
            input.page_workspace.len < capacities.max_page_bytes or
            input.compressed_workspace.len < capacities.max_compressed_bytes or
            input.index_workspace.len < capacities.max_index_entries)
        {
            return error.InvalidResources;
        }
    }
    try validate_compaction_aliases(resources, capacities, streams_output);
}

fn validate_compaction_aliases(
    resources: *const Resources,
    capacities: Capacities,
    streams_output: bool,
) Error!void {
    const controls = compaction_control_ranges(resources, capacities);
    const output = compaction_output_ranges(resources, streams_output);
    try validate_disjoint(&output);
    try validate_disjoint_groups(&controls, &output);
    const inputs = resources.compaction_job_inputs[0..capacities.max_compaction_inputs];
    for (inputs, 0..) |input, index| {
        const ranges = compaction_input_ranges(input);
        try validate_disjoint(&ranges);
        try validate_disjoint_groups(&controls, &ranges);
        try validate_disjoint_groups(&output, &ranges);
        for (inputs[index + 1 ..]) |later| {
            const later_ranges = compaction_input_ranges(later);
            try validate_disjoint_groups(&ranges, &later_ranges);
        }
    }
}

fn compaction_control_ranges(
    resources: *const Resources,
    capacities: Capacities,
) [6][]const u8 {
    return .{
        std.mem.asBytes(resources),
        std.mem.sliceAsBytes(resources.level_listings[0..capacities.listing_entries]),
        std.mem.sliceAsBytes(resources.restore_plan[0..capacities.max_restore_files]),
        std.mem.sliceAsBytes(resources.retention_plan[0..capacities.max_files_per_level]),
        std.mem.sliceAsBytes(
            resources.compaction_job_inputs[0..capacities.max_compaction_inputs],
        ),
        std.mem.sliceAsBytes(
            resources.compaction_inputs[0..capacities.max_compaction_inputs],
        ),
    };
}

fn compaction_input_ranges(input: replica.CompactionJobInput) [4][]const u8 {
    return .{
        input.read_workspace,
        input.page_workspace,
        input.compressed_workspace,
        std.mem.sliceAsBytes(input.index_workspace),
    };
}

fn compaction_output_ranges(
    resources: *const Resources,
    streams_output: bool,
) [4][]const u8 {
    return .{
        if (streams_output)
            resources.compaction_output_storage[0..0]
        else
            resources.compaction_output_storage,
        resources.compaction_output_compressed_workspace,
        std.mem.asBytes(resources.compaction_output_compression_workspace),
        std.mem.sliceAsBytes(resources.compaction_output_index_workspace),
    };
}

fn set_checkpoint_policy(session: *capture.Session, config: *const StableConfig) void {
    session.checkpoint_threshold_bytes = config.checkpoint_threshold_bytes;
    session.checkpoint_interval_ms = config.checkpoint_interval_ms;
    session.checkpoint_max_frames = config.checkpoint_max_frames;
}

fn source_after(source: []const ltx.FileInfo, covered: ltx.TXID) []const ltx.FileInfo {
    var index: usize = 0;
    while (index < source.len and source[index].max_txid.value <= covered.value) {
        index += 1;
    }
    return source[index..];
}

fn newest_snapshot(listed: []const ltx.FileInfo) ?ltx.FileInfo {
    var newest: ?ltx.FileInfo = null;
    for (listed) |info| {
        if (newest == null or info.max_txid.value > newest.?.max_txid.value) {
            newest = info;
        }
    }
    return newest;
}

fn make_anchor(txid: ltx.TXID, storage: *[1]ltx.FileInfo) []const ltx.FileInfo {
    if (txid.value == 0) return &.{};
    storage[0] = .{
        .level = 0,
        .min_txid = ltx.TXID.init(1),
        .max_txid = txid,
        .size_bytes = 0,
    };
    return storage;
}

fn file_info_from_verified(level: u8, verified: ltx.VerifiedLTX) ltx.FileInfo {
    return .{
        .level = level,
        .min_txid = verified.header.min_txid,
        .max_txid = verified.header.max_txid,
        .size_bytes = verified.byte_count,
        .created_at_ms = verified.header.timestamp_ms,
    };
}

fn make_maintenance_report(
    destination_level: u8,
    verified: ltx.VerifiedLTX,
    input_count: usize,
    deleted_count: u64,
) MaintenanceReport {
    return .{
        .destination_level = destination_level,
        .identity = .{
            .min_txid = verified.header.min_txid,
            .max_txid = verified.header.max_txid,
        },
        .input_file_count = @intCast(input_count),
        .deleted_file_count = deleted_count,
        .page_count = verified.page_count,
    };
}

fn contains(upper: ltx.FileInfo, lower: ltx.FileInfo) bool {
    return upper.min_txid.value <= lower.min_txid.value and
        lower.max_txid.value <= upper.max_txid.value;
}

fn same_identity(left: ltx.FileInfo, right: ltx.FileInfo) bool {
    return left.level == right.level and
        left.min_txid.value == right.min_txid.value and
        left.max_txid.value == right.max_txid.value;
}

fn validate_disjoint(ranges: []const []const u8) Error!void {
    for (ranges, 0..) |left, index| {
        for (ranges[index + 1 ..]) |right| {
            if (slices_overlap(left, right)) return error.InvalidResources;
        }
    }
}

fn validate_disjoint_groups(
    left_ranges: []const []const u8,
    right_ranges: []const []const u8,
) Error!void {
    for (left_ranges) |left| {
        for (right_ranges) |right| {
            if (slices_overlap(left, right)) return error.InvalidResources;
        }
    }
}

fn slices_overlap(left: []const u8, right: []const u8) bool {
    if (left.len == 0 or right.len == 0) return false;
    const left_start = @intFromPtr(left.ptr);
    const right_start = @intFromPtr(right.ptr);
    const left_end = std.math.add(usize, left_start, left.len) catch return true;
    const right_end = std.math.add(usize, right_start, right.len) catch return true;
    return left_start < right_end and right_start < left_end;
}

fn cast_usize(value: anytype) !usize {
    return std.math.cast(usize, value) orelse error.InvalidConfiguration;
}

fn add_usize(left: usize, right: usize) !usize {
    return std.math.add(usize, left, right) catch error.InvalidConfiguration;
}

fn mul_usize(left: usize, right: usize) !usize {
    return std.math.mul(usize, left, right) catch error.InvalidConfiguration;
}
