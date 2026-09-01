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

pub const ResourceBindError = error{
    InvalidConfiguration,
    ResourceBudgetOverflow,
    ArenaCapacityExceeded,
};

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

    /// Capacity sufficient for an arbitrary arena base address. The total
    /// includes worst-case padding before the over-aligned descriptor.
    pub fn arena_capacity_bytes(
        config: Config,
        client: object.Client,
    ) ResourceBindError!usize {
        return (try plan_resources(config, client)).arena_capacity_bytes;
    }

    /// Binds one complete controller resource set. The returned descriptor
    /// lives inside `arena`; both must remain stable through `finish()`.
    pub fn bind(
        config: Config,
        client: object.Client,
        arena: []u8,
    ) ResourceBindError!*Resources {
        return bind_resources(try plan_resources(config, client), arena);
    }
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

pub const MaintenanceReconciliationReport = struct {
    destination_level: u8,
    covered_through_txid: ltx.TXID,
    verified_file_count: u32,
    deleted_file_count: u64,
};

pub const MaintenanceResult = union(enum) {
    idle,
    /// A previously published upper restore plan was fully verified before
    /// covered source objects or superseded snapshots were removed. This
    /// bounded call returns before compacting any uncovered tail; call
    /// `maintain` again to continue.
    reconciled: MaintenanceReconciliationReport,
    compacted: MaintenanceReport,
};

pub const ControllerLifecycle = enum {
    ready,
    poisoned,
    finished,
};

pub const ControllerOperation = enum {
    sync,
    restore,
    maintain,
};

pub const OperationCounters = struct {
    /// Calls that passed lifecycle and argument validation and entered work.
    accepted_count: u64 = 0,
    /// Calls returned before work because entry validation failed.
    rejected_count: u64 = 0,
    /// Accepted calls that returned a result, including unchanged or idle.
    succeeded_count: u64 = 0,
    /// Accepted calls that returned an error, whether or not they poisoned.
    failed_count: u64 = 0,
};

pub const OperationFailure = struct {
    operation: ControllerOperation,
    cause: Error,
};

pub const LastOperation = union(enum) {
    sync: SyncResult,
    restore: RestoreReport,
    maintain: MaintenanceResult,
    failed: OperationFailure,
};

/// A copied, pointer-free observation of controller activity. It is intended
/// for inspection between synchronous calls, including after poison or finish.
/// Rejected calls update only their counter and preserve the last accepted
/// result or failure. Initialization, queries, diagnostics, and finish are not
/// counted. Counters saturate independently; `counters_saturated` becomes
/// sticky when an increment cannot be represented.
pub const ControllerDiagnostics = struct {
    lifecycle: ControllerLifecycle,
    sync: OperationCounters = .{},
    restore: OperationCounters = .{},
    maintain: OperationCounters = .{},
    last_accepted_operation: ?LastOperation = null,
    counters_saturated: bool = false,
};

const State = enum {
    initializing,
    ready,
    running,
    poisoned,
    finished,
};

const DiagnosticState = struct {
    sync: OperationCounters = .{},
    restore: OperationCounters = .{},
    maintain: OperationCounters = .{},
    last_accepted_operation: ?LastOperation = null,
    counters_saturated: bool = false,
};

const FailureDisposition = enum {
    ready,
    poisoned,
};

const Capacities = struct {
    max_output_bytes: usize,
    read_workspace_bytes: usize,
    max_page_bytes: usize,
    max_compressed_bytes: usize,
    max_index_entries: usize,
    max_wal_bytes: usize,
    max_wal_pages: usize,
    map_seen_bytes: usize,
    max_files_per_level: usize,
    max_restore_files: usize,
    max_compaction_inputs: usize,
    listing_entries: usize,
};

const InputBankCapacities = struct {
    read_bytes: usize,
    page_bytes: usize,
    compressed_bytes: usize,
    index_entries: usize,
};

const ResourcePlan = struct {
    capacities: Capacities,
    input_banks: InputBankCapacities,
    streams_output: bool,
    layout_bytes: usize,
    arena_capacity_bytes: usize,
};

const resource_alignment = blk: {
    var result: usize = @alignOf(Resources);
    for ([_]usize{
        @alignOf(wal.PageSlot),
        @alignOf(u32),
        @alignOf(wal.PageMapEntry),
        @alignOf(ltx.LZ4CompressionWorkspace),
        @alignOf(ltx.PageIndexEntry),
        @alignOf(ltx.FileInfo),
        @alignOf(replica.CompactionJobInput),
        @alignOf(ltx.CompactionInput),
    }) |candidate| {
        if (candidate > result) result = candidate;
    }
    break :blk result;
};

const LayoutSizer = struct {
    offset_bytes: usize = 0,

    fn reserve_bytes(
        self: *LayoutSizer,
        count_bytes: usize,
    ) ResourceBindError!void {
        self.offset_bytes = try resource_add(self.offset_bytes, count_bytes);
    }

    fn reserve_aligned(
        self: *LayoutSizer,
        count_bytes: usize,
        alignment_bytes: usize,
    ) ResourceBindError!void {
        std.debug.assert(std.math.isPowerOfTwo(alignment_bytes));
        const mask = alignment_bytes - 1;
        const misalignment = self.offset_bytes & mask;
        const padding = if (misalignment == 0)
            0
        else
            alignment_bytes - misalignment;
        self.offset_bytes = try resource_add(self.offset_bytes, padding);
        self.offset_bytes = try resource_add(self.offset_bytes, count_bytes);
    }

    fn reserve_slice(
        self: *LayoutSizer,
        comptime T: type,
        count: usize,
    ) ResourceBindError!void {
        const count_bytes = try resource_mul(count, @sizeOf(T));
        try self.reserve_aligned(count_bytes, @alignOf(T));
    }
};

const BoundControls = struct {
    level_listings: []ltx.FileInfo,
    restore_plan: []ltx.FileInfo,
    retention_plan: []ltx.FileInfo,
    job_inputs: []replica.CompactionJobInput,
    compaction_inputs: []ltx.CompactionInput,
};

const BoundRestore = struct {
    read_workspace: []u8,
    page_workspace: []u8,
    compressed_workspace: []u8,
    index_workspace: []ltx.PageIndexEntry,
};

const BoundCompaction = struct {
    output_storage: []u8,
    output_compressed_workspace: []u8,
    output_compression_workspace: *ltx.LZ4CompressionWorkspace,
    output_index_workspace: []ltx.PageIndexEntry,
};

fn plan_resources(
    config: Config,
    client: object.Client,
) ResourceBindError!ResourcePlan {
    const capacities = try calculate_capacities(config);
    const input_count = capacities.max_compaction_inputs;
    const banks = InputBankCapacities{
        .read_bytes = try resource_mul(input_count, capacities.read_workspace_bytes),
        .page_bytes = try resource_mul(input_count, capacities.max_page_bytes),
        .compressed_bytes = try resource_mul(
            input_count,
            capacities.max_compressed_bytes,
        ),
        .index_entries = try resource_mul(input_count, capacities.max_index_entries),
    };
    const streams_output = client.supports_write_sessions();
    const layout_bytes = try resource_layout_bytes(
        capacities,
        banks,
        streams_output,
    );
    return .{
        .capacities = capacities,
        .input_banks = banks,
        .streams_output = streams_output,
        .layout_bytes = layout_bytes,
        .arena_capacity_bytes = try resource_add(
            resource_alignment - 1,
            layout_bytes,
        ),
    };
}

fn resource_layout_bytes(
    capacities: Capacities,
    banks: InputBankCapacities,
    streams_output: bool,
) ResourceBindError!usize {
    var sizer = LayoutSizer{};
    try sizer.reserve_aligned(@sizeOf(Resources), resource_alignment);
    try size_capture_layout(&sizer, capacities, streams_output);
    try size_control_layout(&sizer, capacities);
    try size_restore_layout(&sizer, capacities);
    try size_compaction_layout(&sizer, capacities, banks, streams_output);
    return sizer.offset_bytes;
}

fn size_capture_layout(
    sizer: *LayoutSizer,
    capacities: Capacities,
    streams_output: bool,
) ResourceBindError!void {
    try sizer.reserve_bytes(capacities.max_wal_bytes);
    try sizer.reserve_slice(wal.PageSlot, capacities.max_wal_pages);
    try sizer.reserve_slice(u32, capacities.max_wal_pages);
    try sizer.reserve_bytes(capacities.map_seen_bytes);
    try sizer.reserve_slice(wal.PageMapEntry, capacities.max_wal_pages);
    if (!streams_output) try sizer.reserve_bytes(capacities.max_output_bytes);
    try sizer.reserve_bytes(capacities.max_page_bytes);
    try sizer.reserve_bytes(capacities.max_compressed_bytes);
    try sizer.reserve_slice(ltx.LZ4CompressionWorkspace, 1);
    try sizer.reserve_slice(ltx.PageIndexEntry, capacities.max_index_entries);
}

fn size_control_layout(
    sizer: *LayoutSizer,
    capacities: Capacities,
) ResourceBindError!void {
    try sizer.reserve_slice(ltx.FileInfo, capacities.listing_entries);
    try sizer.reserve_slice(ltx.FileInfo, capacities.max_restore_files);
    try sizer.reserve_slice(ltx.FileInfo, capacities.max_files_per_level);
    try sizer.reserve_slice(
        replica.CompactionJobInput,
        capacities.max_compaction_inputs,
    );
    try sizer.reserve_slice(
        ltx.CompactionInput,
        capacities.max_compaction_inputs,
    );
}

fn size_restore_layout(
    sizer: *LayoutSizer,
    capacities: Capacities,
) ResourceBindError!void {
    try sizer.reserve_bytes(capacities.read_workspace_bytes);
    try sizer.reserve_bytes(capacities.max_page_bytes);
    try sizer.reserve_bytes(capacities.max_compressed_bytes);
    try sizer.reserve_slice(ltx.PageIndexEntry, capacities.max_index_entries);
}

fn size_compaction_layout(
    sizer: *LayoutSizer,
    capacities: Capacities,
    banks: InputBankCapacities,
    streams_output: bool,
) ResourceBindError!void {
    try sizer.reserve_bytes(banks.read_bytes);
    try sizer.reserve_bytes(banks.page_bytes);
    try sizer.reserve_bytes(banks.compressed_bytes);
    try sizer.reserve_slice(ltx.PageIndexEntry, banks.index_entries);
    if (!streams_output) try sizer.reserve_bytes(capacities.max_output_bytes);
    try sizer.reserve_bytes(capacities.max_compressed_bytes);
    try sizer.reserve_slice(ltx.LZ4CompressionWorkspace, 1);
    try sizer.reserve_slice(ltx.PageIndexEntry, capacities.max_index_entries);
}

fn bind_resources(
    plan: ResourcePlan,
    arena: []u8,
) ResourceBindError!*Resources {
    if (arena.len < plan.arena_capacity_bytes) {
        return error.ArenaCapacityExceeded;
    }
    var cursor = resource_model.ArenaCursor.init(arena);
    const descriptor_bytes = try arena_bind_aligned_bytes(
        &cursor,
        @sizeOf(Resources),
        resource_alignment,
    );
    const resources: *Resources = @ptrCast(@alignCast(descriptor_bytes.ptr));
    const empty = arena[0..0];
    const capture_workspaces = try bind_capture(
        &cursor,
        plan.capacities,
        plan.streams_output,
        empty,
    );
    const controls = try bind_controls(&cursor, plan.capacities);
    const restore = try bind_restore(&cursor, plan.capacities);
    const compaction = try bind_compaction(
        &cursor,
        plan,
        controls.job_inputs,
        empty,
    );
    const descriptor_address = @intFromPtr(resources);
    const arena_address = @intFromPtr(arena.ptr);
    const padding_bytes = descriptor_address - arena_address;
    std.debug.assert(cursor.consumed_bytes() == padding_bytes + plan.layout_bytes);
    resources.* = make_resources(capture_workspaces, controls, restore, compaction);
    return resources;
}

fn bind_capture(
    cursor: *resource_model.ArenaCursor,
    capacities: Capacities,
    streams_output: bool,
    empty: []u8,
) ResourceBindError!capture.Workspaces {
    const wal_storage = try arena_bind_bytes(cursor, capacities.max_wal_bytes);
    const map_slots = try arena_bind_slice(
        cursor,
        wal.PageSlot,
        capacities.max_wal_pages,
    );
    const map_pending = try arena_bind_slice(cursor, u32, capacities.max_wal_pages);
    const map_seen = try arena_bind_bytes(cursor, capacities.map_seen_bytes);
    const map_entries = try arena_bind_slice(
        cursor,
        wal.PageMapEntry,
        capacities.max_wal_pages,
    );
    const output = if (streams_output)
        empty
    else
        try arena_bind_bytes(cursor, capacities.max_output_bytes);
    const page = try arena_bind_bytes(cursor, capacities.max_page_bytes);
    const compressed = try arena_bind_bytes(cursor, capacities.max_compressed_bytes);
    const compression = try arena_bind_slice(cursor, ltx.LZ4CompressionWorkspace, 1);
    const index = try arena_bind_slice(
        cursor,
        ltx.PageIndexEntry,
        capacities.max_index_entries,
    );
    return .{
        .wal_storage = wal_storage,
        .map_slots = map_slots,
        .map_pending = map_pending,
        .map_seen = map_seen,
        .map_entries = map_entries,
        .output_storage = output,
        .page_workspace = page,
        .compressed_workspace = compressed,
        .compression_workspace = &compression[0],
        .index_workspace = index,
    };
}

fn bind_controls(
    cursor: *resource_model.ArenaCursor,
    capacities: Capacities,
) ResourceBindError!BoundControls {
    return .{
        .level_listings = try arena_bind_slice(
            cursor,
            ltx.FileInfo,
            capacities.listing_entries,
        ),
        .restore_plan = try arena_bind_slice(
            cursor,
            ltx.FileInfo,
            capacities.max_restore_files,
        ),
        .retention_plan = try arena_bind_slice(
            cursor,
            ltx.FileInfo,
            capacities.max_files_per_level,
        ),
        .job_inputs = try arena_bind_slice(
            cursor,
            replica.CompactionJobInput,
            capacities.max_compaction_inputs,
        ),
        .compaction_inputs = try arena_bind_slice(
            cursor,
            ltx.CompactionInput,
            capacities.max_compaction_inputs,
        ),
    };
}

fn bind_restore(
    cursor: *resource_model.ArenaCursor,
    capacities: Capacities,
) ResourceBindError!BoundRestore {
    return .{
        .read_workspace = try arena_bind_bytes(
            cursor,
            capacities.read_workspace_bytes,
        ),
        .page_workspace = try arena_bind_bytes(cursor, capacities.max_page_bytes),
        .compressed_workspace = try arena_bind_bytes(
            cursor,
            capacities.max_compressed_bytes,
        ),
        .index_workspace = try arena_bind_slice(
            cursor,
            ltx.PageIndexEntry,
            capacities.max_index_entries,
        ),
    };
}

fn bind_compaction(
    cursor: *resource_model.ArenaCursor,
    plan: ResourcePlan,
    job_inputs: []replica.CompactionJobInput,
    empty: []u8,
) ResourceBindError!BoundCompaction {
    const read_bank = try arena_bind_bytes(cursor, plan.input_banks.read_bytes);
    const page_bank = try arena_bind_bytes(cursor, plan.input_banks.page_bytes);
    const compressed_bank = try arena_bind_bytes(
        cursor,
        plan.input_banks.compressed_bytes,
    );
    const index_bank = try arena_bind_slice(
        cursor,
        ltx.PageIndexEntry,
        plan.input_banks.index_entries,
    );
    const output = if (plan.streams_output)
        empty
    else
        try arena_bind_bytes(cursor, plan.capacities.max_output_bytes);
    const output_compressed = try arena_bind_bytes(
        cursor,
        plan.capacities.max_compressed_bytes,
    );
    const output_compression = try arena_bind_slice(
        cursor,
        ltx.LZ4CompressionWorkspace,
        1,
    );
    const output_index = try arena_bind_slice(
        cursor,
        ltx.PageIndexEntry,
        plan.capacities.max_index_entries,
    );
    populate_job_inputs(
        job_inputs,
        plan.capacities,
        read_bank,
        page_bank,
        compressed_bank,
        index_bank,
    );
    return .{
        .output_storage = output,
        .output_compressed_workspace = output_compressed,
        .output_compression_workspace = &output_compression[0],
        .output_index_workspace = output_index,
    };
}

fn populate_job_inputs(
    job_inputs: []replica.CompactionJobInput,
    capacities: Capacities,
    read_bank: []u8,
    page_bank: []u8,
    compressed_bank: []u8,
    index_bank: []ltx.PageIndexEntry,
) void {
    var read_offset: usize = 0;
    var page_offset: usize = 0;
    var compressed_offset: usize = 0;
    var index_offset: usize = 0;
    for (job_inputs) |*input| {
        input.* = .{
            .read_workspace = read_bank[read_offset..][0..capacities.read_workspace_bytes],
            .page_workspace = page_bank[page_offset..][0..capacities.max_page_bytes],
            .compressed_workspace = compressed_bank[compressed_offset..][0..capacities.max_compressed_bytes],
            .index_workspace = index_bank[index_offset..][0..capacities.max_index_entries],
        };
        read_offset += capacities.read_workspace_bytes;
        page_offset += capacities.max_page_bytes;
        compressed_offset += capacities.max_compressed_bytes;
        index_offset += capacities.max_index_entries;
    }
    std.debug.assert(read_offset == read_bank.len);
    std.debug.assert(page_offset == page_bank.len);
    std.debug.assert(compressed_offset == compressed_bank.len);
    std.debug.assert(index_offset == index_bank.len);
}

fn make_resources(
    capture_workspaces: capture.Workspaces,
    controls: BoundControls,
    restore: BoundRestore,
    compaction: BoundCompaction,
) Resources {
    return .{
        .capture = capture_workspaces,
        .level_listings = controls.level_listings,
        .restore_plan = controls.restore_plan,
        .retention_plan = controls.retention_plan,
        .restore_read_workspace = restore.read_workspace,
        .restore_page_workspace = restore.page_workspace,
        .restore_compressed_workspace = restore.compressed_workspace,
        .restore_index_workspace = restore.index_workspace,
        .compaction_job_inputs = controls.job_inputs,
        .compaction_inputs = controls.compaction_inputs,
        .compaction_output_storage = compaction.output_storage,
        .compaction_output_compressed_workspace = compaction.output_compressed_workspace,
        .compaction_output_compression_workspace = compaction.output_compression_workspace,
        .compaction_output_index_workspace = compaction.output_index_workspace,
    };
}

fn arena_bind_bytes(
    cursor: *resource_model.ArenaCursor,
    count_bytes: usize,
) ResourceBindError![]u8 {
    return cursor.bind_bytes(count_bytes) catch |err| switch (err) {
        error.ResourceBudgetOverflow => return error.ResourceBudgetOverflow,
        error.ArenaCapacityExceeded => return error.ArenaCapacityExceeded,
        else => unreachable,
    };
}

fn arena_bind_aligned_bytes(
    cursor: *resource_model.ArenaCursor,
    count_bytes: usize,
    alignment_bytes: usize,
) ResourceBindError![]u8 {
    return cursor.bind_aligned_bytes(count_bytes, alignment_bytes) catch |err| switch (err) {
        error.ResourceBudgetOverflow => return error.ResourceBudgetOverflow,
        error.ArenaCapacityExceeded => return error.ArenaCapacityExceeded,
        else => unreachable,
    };
}

fn arena_bind_slice(
    cursor: *resource_model.ArenaCursor,
    comptime T: type,
    count: usize,
) ResourceBindError![]T {
    return cursor.bind_slice(T, count) catch |err| switch (err) {
        error.ResourceBudgetOverflow => return error.ResourceBudgetOverflow,
        error.ArenaCapacityExceeded => return error.ArenaCapacityExceeded,
        else => unreachable,
    };
}

/// One synchronous, single-owner controller. Do not copy it after `init`.
pub const Controller = struct {
    session: capture.Session,
    client: object.Client,
    config: StableConfig,
    resources: *Resources,
    level_lists: [level_count][]const ltx.FileInfo = @splat(&.{}),
    last_sync_timestamp_ms: ?i64 = null,
    state: State = .initializing,
    diagnostic_state: DiagnosticState = .{},

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
        try self.require_operation_ready(.sync);
        self.validate_sync_timestamp(timestamp_ms) catch |err| {
            self.reject_operation(.sync);
            return err;
        };
        self.accept_operation(.sync);
        const result = self.sync_internal(timestamp_ms) catch |err| {
            self.fail_operation(.sync, err, .poisoned);
            return err;
        };
        self.succeed_operation(.{ .sync = result });
        return result;
    }

    /// The backend target must be distinct from this controller's live
    /// database and quiesced by the host for the entire restore.
    pub fn restore(
        self: *Controller,
        target_txid: ltx.TXID,
        backend: ltx.ApplyBackend,
    ) Error!RestoreReport {
        try self.require_operation_ready(.restore);
        self.accept_operation(.restore);
        const report = self.restore_internal(target_txid, backend) catch |err| {
            const disposition: FailureDisposition = if (err == error.TxNotAvailable)
                .ready
            else
                .poisoned;
            self.fail_operation(.restore, err, disposition);
            return err;
        };
        self.succeed_operation(.{ .restore = report });
        return report;
    }

    pub fn maintain(
        self: *Controller,
        destination_level: u8,
    ) Error!MaintenanceResult {
        try self.require_operation_ready(.maintain);
        _ = self.source_level(destination_level) catch |err| {
            self.reject_operation(.maintain);
            return err;
        };
        self.accept_operation(.maintain);
        const report = self.maintain_internal(destination_level) catch |err| {
            self.fail_operation(.maintain, err, .poisoned);
            return err;
        };
        self.succeed_operation(.{ .maintain = report });
        return report;
    }

    pub fn diagnostics(self: *const Controller) ControllerDiagnostics {
        return .{
            .lifecycle = switch (self.state) {
                .ready => .ready,
                .poisoned => .poisoned,
                .finished => .finished,
                .initializing, .running => unreachable,
            },
            .sync = self.diagnostic_state.sync,
            .restore = self.diagnostic_state.restore,
            .maintain = self.diagnostic_state.maintain,
            .last_accepted_operation = self.diagnostic_state.last_accepted_operation,
            .counters_saturated = self.diagnostic_state.counters_saturated,
        };
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
        const upper_plan = try self.upper_restore_plan(destination_level);
        const coverage_txid = restore_plan_coverage(upper_plan);
        if (try self.reconcile_covered_objects(
            destination_level,
            source_level_value,
            upper_plan,
        )) |report| return .{ .reconciled = report };
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

    fn upper_restore_plan(
        self: *Controller,
        destination_level: u8,
    ) Error![]const ltx.FileInfo {
        var upper_lists: [level_count][]const ltx.FileInfo = @splat(&.{});
        for (destination_level..level_count) |level| {
            upper_lists[level] = self.level_lists[level];
        }
        return replica.calc_restore_plan(
            &upper_lists,
            ltx.TXID.init(0),
            self.resources.restore_plan[0..self.config.max_restore_files],
        ) catch |err| switch (err) {
            error.TxNotAvailable => return self.resources.restore_plan[0..0],
            else => return err,
        };
    }

    fn reconcile_covered_objects(
        self: *Controller,
        destination_level: u8,
        source_level_value: u8,
        upper_plan: []const ltx.FileInfo,
    ) Error!?MaintenanceReconciliationReport {
        if (upper_plan.len == 0) return null;
        const covered = replica.plan_retention(
            self.level_lists[source_level_value],
            upper_plan,
            self.resources.retention_plan[0..self.config.max_files_per_level],
        );
        const snapshot = if (destination_level == ltx.snapshot_level)
            upper_plan[0]
        else
            null;
        const covered_snapshot_count = if (snapshot) |info|
            self.count_covered_snapshots(info)
        else
            0;
        if (covered.len == 0 and covered_snapshot_count == 0) return null;
        var job = self.verification_job();
        const position_value = try job.run(upper_plan);
        const coverage_txid = restore_plan_coverage(upper_plan);
        if (position_value.txid.value != coverage_txid.value) {
            return error.ObjectIdentityMismatch;
        }
        const verified_file_count = std.math.cast(u32, upper_plan.len) orelse
            return error.PlanCapacityExceeded;
        var deleted_file_count = std.math.cast(u64, covered.len) orelse
            return error.PlanCapacityExceeded;
        if (covered.len != 0) try self.client.delete(covered);
        if (snapshot) |info| {
            const snapshot_deleted = try self.delete_covered_snapshots(info);
            deleted_file_count = std.math.add(
                u64,
                deleted_file_count,
                snapshot_deleted,
            ) catch return error.PlanCapacityExceeded;
        }
        return .{
            .destination_level = destination_level,
            .covered_through_txid = coverage_txid,
            .verified_file_count = verified_file_count,
            .deleted_file_count = deleted_file_count,
        };
    }

    fn verification_job(self: *Controller) replica.VerificationJob {
        return .{
            .client = self.client,
            .codec_limits = self.config.codec_limits,
            .read_workspace = self.resources.restore_read_workspace,
            .page_workspace = self.resources.restore_page_workspace,
            .compressed_workspace = self.resources.restore_compressed_workspace,
            .index_workspace = self.resources.restore_index_workspace,
        };
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

    fn count_covered_snapshots(self: *const Controller, output: ltx.FileInfo) usize {
        var count: usize = 0;
        for (self.level_lists[ltx.snapshot_level]) |info| {
            if (!same_identity(info, output) and contains(output, info)) count += 1;
        }
        return count;
    }

    fn require_ready(self: *const Controller) Error!void {
        switch (self.state) {
            .ready => {},
            .poisoned => return error.Poisoned,
            .finished => return error.Finished,
            .initializing, .running => return error.InvalidState,
        }
    }

    fn require_operation_ready(
        self: *Controller,
        operation: ControllerOperation,
    ) Error!void {
        self.require_ready() catch |err| {
            self.reject_operation(operation);
            return err;
        };
    }

    fn accept_operation(self: *Controller, operation: ControllerOperation) void {
        std.debug.assert(self.state == .ready);
        increment_counter(
            &self.operation_counters(operation).accepted_count,
            &self.diagnostic_state.counters_saturated,
        );
        self.state = .running;
    }

    fn reject_operation(self: *Controller, operation: ControllerOperation) void {
        increment_counter(
            &self.operation_counters(operation).rejected_count,
            &self.diagnostic_state.counters_saturated,
        );
    }

    fn succeed_operation(self: *Controller, last: LastOperation) void {
        std.debug.assert(self.state == .running);
        const operation: ControllerOperation = switch (last) {
            .sync => .sync,
            .restore => .restore,
            .maintain => .maintain,
            .failed => unreachable,
        };
        increment_counter(
            &self.operation_counters(operation).succeeded_count,
            &self.diagnostic_state.counters_saturated,
        );
        self.diagnostic_state.last_accepted_operation = last;
        self.state = .ready;
    }

    fn fail_operation(
        self: *Controller,
        operation: ControllerOperation,
        cause: Error,
        disposition: FailureDisposition,
    ) void {
        std.debug.assert(self.state == .running);
        increment_counter(
            &self.operation_counters(operation).failed_count,
            &self.diagnostic_state.counters_saturated,
        );
        self.diagnostic_state.last_accepted_operation = .{ .failed = .{
            .operation = operation,
            .cause = cause,
        } };
        self.state = switch (disposition) {
            .ready => .ready,
            .poisoned => .poisoned,
        };
    }

    fn operation_counters(
        self: *Controller,
        operation: ControllerOperation,
    ) *OperationCounters {
        return switch (operation) {
            .sync => &self.diagnostic_state.sync,
            .restore => &self.diagnostic_state.restore,
            .maintain => &self.diagnostic_state.maintain,
        };
    }

    fn validate_sync_timestamp(self: *const Controller, timestamp_ms: i64) Error!void {
        if (timestamp_ms < 0) return error.InvalidTimestamp;
        if (self.last_sync_timestamp_ms) |previous| {
            if (timestamp_ms < previous) return error.TimestampRegression;
        }
    }
};

fn validate_configuration(options: Options) Error!Capacities {
    if (options.database_name.len == 0) return error.InvalidConfiguration;
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

fn calculate_capacities(config: Config) ResourceBindError!Capacities {
    try validate_resource_configuration(config);
    const max_output: usize = try resource_cast(config.codec_limits.max_output_bytes);
    const read_workspace: usize = try resource_cast(config.read_workspace_bytes);
    const max_page: usize = try resource_cast(config.codec_limits.max_page_size);
    const max_compressed: usize = try resource_cast(
        config.codec_limits.max_compressed_page_size,
    );
    const max_index: usize = try resource_cast(
        config.codec_limits.max_page_index_entries,
    );
    const max_wal_pages: usize = try resource_cast(config.wal_limits.max_pages);
    const frame_bytes = try resource_add(
        wal.frame_header_size_bytes,
        try resource_cast(config.wal_limits.max_page_size),
    );
    const max_wal = try resource_add(
        wal.header_size_bytes,
        try resource_mul(try resource_cast(config.wal_limits.max_frames), frame_bytes),
    );
    const files: usize = try resource_cast(config.max_files_per_level);
    return .{
        .max_output_bytes = max_output,
        .read_workspace_bytes = read_workspace,
        .max_page_bytes = max_page,
        .max_compressed_bytes = max_compressed,
        .max_index_entries = max_index,
        .max_wal_bytes = max_wal,
        .max_wal_pages = max_wal_pages,
        .map_seen_bytes = (try resource_add(max_wal_pages, 7)) / 8,
        .max_files_per_level = files,
        .max_restore_files = try resource_cast(config.max_restore_files),
        .max_compaction_inputs = try resource_cast(
            config.compaction_limits.max_inputs,
        ),
        .listing_entries = try resource_mul(level_count, files),
    };
}

fn validate_resource_configuration(config: Config) ResourceBindError!void {
    config.codec_limits.validate() catch return error.InvalidConfiguration;
    config.wal_limits.validate() catch return error.InvalidConfiguration;
    config.apply_limits.validate() catch return error.InvalidConfiguration;
    config.compaction_limits.validate() catch return error.InvalidConfiguration;
    config.levels.validate() catch return error.InvalidConfiguration;
    _ = resource_model.encoder_workspace_bytes(config.codec_limits) catch |err| {
        return switch (err) {
            error.ResourceBudgetOverflow => error.ResourceBudgetOverflow,
            else => error.InvalidConfiguration,
        };
    };
    if (config.max_files_per_level == 0 or
        config.max_restore_files == 0 or
        config.max_compaction_input_bytes == 0 or
        config.read_workspace_bytes == 0 or
        config.read_workspace_bytes > config.codec_limits.max_input_bytes or
        config.codec_limits.max_output_bytes > config.codec_limits.max_input_bytes or
        config.max_restore_files < config.compaction_limits.max_inputs)
    {
        return error.InvalidConfiguration;
    }
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
    if (resources.wal_storage.len < capacities.max_wal_bytes or
        resources.map_slots.len < capacities.max_wal_pages or
        resources.map_pending.len < capacities.max_wal_pages or
        resources.map_seen.len < capacities.map_seen_bytes or
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

fn restore_plan_coverage(plan: []const ltx.FileInfo) ltx.TXID {
    if (plan.len == 0) return ltx.TXID.init(0);
    return plan[plan.len - 1].max_txid;
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

fn resource_cast(value: anytype) ResourceBindError!usize {
    return std.math.cast(usize, value) orelse error.ResourceBudgetOverflow;
}

fn resource_add(left: usize, right: usize) ResourceBindError!usize {
    return std.math.add(usize, left, right) catch error.ResourceBudgetOverflow;
}

fn resource_mul(left: usize, right: usize) ResourceBindError!usize {
    return std.math.mul(usize, left, right) catch error.ResourceBudgetOverflow;
}

fn increment_counter(counter: *u64, counters_saturated: *bool) void {
    if (counter.* == std.math.maxInt(u64)) {
        counters_saturated.* = true;
        return;
    }
    counter.* += 1;
}

test "operation counter saturation is sticky only after a blocked increment" {
    var counter = std.math.maxInt(u64) - 1;
    var counters_saturated = false;

    increment_counter(&counter, &counters_saturated);
    try std.testing.expectEqual(std.math.maxInt(u64), counter);
    try std.testing.expect(!counters_saturated);

    increment_counter(&counter, &counters_saturated);
    try std.testing.expectEqual(std.math.maxInt(u64), counter);
    try std.testing.expect(counters_saturated);

    counter = 0;
    increment_counter(&counter, &counters_saturated);
    try std.testing.expectEqual(@as(u64, 1), counter);
    try std.testing.expect(counters_saturated);
}
