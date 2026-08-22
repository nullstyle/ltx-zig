const std = @import("std");
const checksum = @import("checksum.zig");
const Decoder = @import("decoder.zig").Decoder;
const format = @import("format.zig");
const Limits = @import("limits.zig").Limits;
const Reader = @import("transport.zig").Reader;
const workspace = @import("workspace.zig");

pub const ApplyLimits = struct {
    max_database_pages: u32,
    max_database_bytes: u64,

    pub fn validate(self: ApplyLimits) error{InvalidLimits}!void {
        if (self.max_database_pages == 0) return error.InvalidLimits;
        if (self.max_database_bytes == 0) return error.InvalidLimits;
    }
};

pub const ApplyMode = enum {
    contiguous,
    replace_snapshot,
};

pub const ApplyState = enum {
    initialized,
    staging,
    published,
    /// The publication commit point could not be resolved. The backend has
    /// ended private staging, but must recover its authoritative state before
    /// another apply begins.
    recovery_required,
    failed,
};

pub const ApplyPlan = struct {
    format_version: format.FormatVersion,
    mode: ApplyMode,
    header: format.Header,
    final_database_size_bytes: u64,
};

pub const ApplyCurrent = struct {
    /// Position bound to the exact authoritative image cloned by `begin`.
    position: format.Position,
    /// Authoritative page-size metadata. `null` means no page size has ever
    /// been established and is valid only as the base of a snapshot.
    page_size: ?u32,
};

pub const StagedPage = struct {
    page_number: u32,
    offset_bytes: u64,
    data: []const u8,
};

/// Storage-neutral private staging. Callbacks must be synchronous,
/// non-reentrant, and keep the staging image immutable except while servicing
/// these calls. Successful `begin` owns an isolated image until `publish`
/// succeeds, `abort` is called, or an indeterminate `publish` ends the stage;
/// failed `begin` owns nothing.
pub const ApplyBackend = struct {
    context: *anyopaque,
    /// Acquires stable current metadata and creates an isolated image at the
    /// plan's exact final size. Snapshots start entirely zero-filled;
    /// incrementals require a page-size-compatible current database and start
    /// as its private copy, resized to the final size. No authoritative state
    /// may change here.
    begin_fn: *const fn (
        context: *anyopaque,
        plan: ApplyPlan,
    ) error{ApplyBeginFailure}!ApplyCurrent,
    /// Copies `page.data` into private staging before returning. The decoder
    /// overwrites that slice on its next operation.
    stage_page_fn: *const fn (
        context: *anyopaque,
        page: StagedPage,
    ) error{ApplyStageFailure}!void,
    /// Fills the whole destination from the exact private image created by
    /// `begin`; short or partial success is forbidden.
    read_page_fn: *const fn (
        context: *anyopaque,
        page_number: u32,
        destination: []u8,
    ) error{ApplyReadFailure}!void,
    /// Atomically compares all authoritative metadata with `expected_current`,
    /// then publishes the staged image, its page size, and verified
    /// post-position together. Ordinary errors leave authoritative state
    /// unchanged and staging active. `ApplyPublishIndeterminate` means the
    /// durable commit point may have been crossed; the backend must end its
    /// stage before returning it, and the caller must run backend recovery.
    publish_fn: *const fn (
        context: *anyopaque,
        expected_current: ApplyCurrent,
        verified: format.VerifiedLTX,
    ) error{
        ApplyPublishFailure,
        ApplyPublishIndeterminate,
        NonContiguousTransition,
        DivergentHistory,
        DatabasePageSizeMismatch,
    }!void,
    /// Discards private staging. It must not fail or change authoritative state.
    abort_fn: *const fn (context: *anyopaque) void,
    /// Stable staging storage, when it can be described as one slice. Reporting
    /// it lets initialization reject aliases with input and codec workspaces.
    backing_bytes: ?[]u8 = null,

    fn begin(self: ApplyBackend, plan: ApplyPlan) format.Error!ApplyCurrent {
        return self.begin_fn(self.context, plan);
    }

    fn stage_page(self: ApplyBackend, page: StagedPage) format.Error!void {
        return self.stage_page_fn(self.context, page);
    }

    fn read_page(
        self: ApplyBackend,
        page_number: u32,
        destination: []u8,
    ) format.Error!void {
        return self.read_page_fn(self.context, page_number, destination);
    }

    fn publish(
        self: ApplyBackend,
        expected_current: ApplyCurrent,
        verified: format.VerifiedLTX,
    ) format.Error!void {
        return self.publish_fn(self.context, expected_current, verified);
    }

    fn abort(self: ApplyBackend) void {
        self.abort_fn(self.context);
    }
};

/// One-shot verified apply session. It owns the decoder state and can publish
/// only after the complete LTX and the resulting private database image verify.
/// An indeterminate publication is terminal and requires backend recovery; it
/// is never followed by `abort` because the backend has already ended staging.
/// This is a stateful, single-owner value: never copy it or operate through
/// copies after initialization.
pub const StagedApplier = struct {
    decoder: Decoder,
    apply_limits: ApplyLimits,
    mode: ApplyMode,
    backend: ApplyBackend,
    page_workspace: []u8,
    state: ApplyState = .initialized,
    staging_active: bool = false,

    pub fn init(
        version: format.FormatVersion,
        codec_limits: Limits,
        apply_limits: ApplyLimits,
        mode: ApplyMode,
        reader: Reader,
        backend: ApplyBackend,
        page_workspace: []u8,
        compressed_workspace: []u8,
        index_workspace: []format.PageIndexEntry,
    ) format.Error!StagedApplier {
        apply_limits.validate() catch return error.InvalidLimits;
        try reject_backend_aliasing(
            backend,
            reader,
            page_workspace,
            compressed_workspace,
            index_workspace,
        );
        const decoder = try Decoder.init(
            version,
            codec_limits,
            reader,
            page_workspace,
            compressed_workspace,
            index_workspace,
        );
        return .{
            .decoder = decoder,
            .apply_limits = apply_limits,
            .mode = mode,
            .backend = backend,
            .page_workspace = page_workspace,
        };
    }

    pub fn current_state(self: *const StagedApplier) ApplyState {
        return self.state;
    }

    pub fn apply(self: *StagedApplier) format.Error!format.VerifiedLTX {
        if (self.state != .initialized) return error.InvalidState;
        return self.apply_internal() catch |err| {
            if (self.state == .recovery_required) {
                std.debug.assert(!self.staging_active);
                std.debug.assert(err == error.ApplyPublishIndeterminate);
                return err;
            }
            const must_abort = self.staging_active;
            self.staging_active = false;
            self.state = .failed;
            if (must_abort) self.backend.abort();
            return err;
        };
    }

    fn apply_internal(self: *StagedApplier) format.Error!format.VerifiedLTX {
        const first = try self.decoder.next();
        const header = switch (first) {
            .header => |value| value,
            else => return error.InvalidState,
        };
        const plan = try self.make_plan(header);

        // Enter the non-reentrant state before invoking caller code. A failed
        // begin promises that it left no private transaction to abort.
        self.state = .staging;
        const current = try self.backend.begin(plan);
        self.staging_active = true;
        try self.check_transition(header, current);

        const verified = try self.consume_verified(plan);
        try self.verify_database_checksum(verified);
        self.backend.publish(current, verified) catch |err| switch (err) {
            error.ApplyPublishIndeterminate => {
                self.staging_active = false;
                self.state = .recovery_required;
                return err;
            },
            else => return err,
        };
        self.staging_active = false;
        self.state = .published;
        return verified;
    }

    fn make_plan(self: *const StagedApplier, header: format.Header) format.Error!ApplyPlan {
        if (header.commit > self.apply_limits.max_database_pages) {
            return error.DatabasePageLimitExceeded;
        }
        const final_size_bytes = std.math.mul(
            u64,
            @as(u64, header.commit),
            @as(u64, header.page_size),
        ) catch return error.DatabaseSizeLimitExceeded;
        if (final_size_bytes > self.apply_limits.max_database_bytes) {
            return error.DatabaseSizeLimitExceeded;
        }
        return .{
            .format_version = self.decoder.selected_format_version(),
            .mode = self.mode,
            .header = header,
            .final_database_size_bytes = final_size_bytes,
        };
    }

    fn check_transition(
        self: *const StagedApplier,
        header: format.Header,
        current: ApplyCurrent,
    ) format.Error!void {
        if (self.mode == .replace_snapshot and header.is_snapshot()) return;
        try header.check_contiguous(current.position);
        if (!header.is_snapshot() and current.page_size != header.page_size) {
            return error.DatabasePageSizeMismatch;
        }
    }

    fn consume_verified(self: *StagedApplier, plan: ApplyPlan) format.Error!format.VerifiedLTX {
        const event_budget = self.decoder.event_budget() - 1;
        var event_count: u64 = 0;
        var page_block_complete = false;
        while (event_count < event_budget) : (event_count += 1) {
            const event = try self.decoder.next();
            switch (event) {
                .header => return error.InvalidState,
                .unverified_page => |page| {
                    if (page_block_complete) return error.InvalidState;
                    try self.stage_page(plan, page);
                },
                .page_block_complete => {
                    if (page_block_complete) return error.InvalidState;
                    page_block_complete = true;
                },
                .verified => |verified| {
                    if (!page_block_complete) return error.InvalidState;
                    std.debug.assert(std.meta.eql(plan.header, verified.header));
                    return verified;
                },
            }
        }
        return error.InvalidState;
    }

    fn stage_page(
        self: *StagedApplier,
        plan: ApplyPlan,
        page: format.UnverifiedPage,
    ) format.Error!void {
        std.debug.assert(page.data.len == plan.header.page_size);
        const page_index = @as(u64, page.header.page_number - 1);
        const offset_bytes = std.math.mul(
            u64,
            page_index,
            @as(u64, plan.header.page_size),
        ) catch return error.InvalidPageNumber;
        const end_bytes = std.math.add(u64, offset_bytes, @as(u64, page.data.len)) catch {
            return error.InvalidPageNumber;
        };
        if (end_bytes > plan.final_database_size_bytes) return error.InvalidPageNumber;
        try self.backend.stage_page(.{
            .page_number = page.header.page_number,
            .offset_bytes = offset_bytes,
            .data = page.data,
        });
    }

    fn verify_database_checksum(
        self: *StagedApplier,
        verified: format.VerifiedLTX,
    ) format.Error!void {
        if (verified.header.no_checksum()) return;
        const page_size: usize = @intCast(verified.header.page_size);
        const page_buffer = self.page_workspace[0..page_size];
        const lock_page = try format.lock_page_number(verified.header.page_size);
        var database_checksum = checksum.rolling_initial();
        var page_index: u64 = 0;
        while (page_index < verified.header.commit) : (page_index += 1) {
            const page_number: u32 = @intCast(page_index + 1);
            if (page_number == lock_page) continue;
            @memset(page_buffer, 0);
            try self.backend.read_page(page_number, page_buffer);
            database_checksum = try checksum.rolling_add(
                database_checksum,
                try checksum.checksum_page(page_number, page_buffer),
            );
        }
        if (database_checksum.value != verified.trailer.post_apply_checksum.value) {
            return error.DatabaseChecksumMismatch;
        }
    }
};

fn reject_backend_aliasing(
    backend: ApplyBackend,
    reader: Reader,
    page_workspace: []u8,
    compressed_workspace: []u8,
    index_workspace: []format.PageIndexEntry,
) format.Error!void {
    const backing = backend.backing_bytes orelse return;
    const index_bytes = std.mem.sliceAsBytes(index_workspace);
    if (workspace.slices_overlap(backing, page_workspace) or
        workspace.slices_overlap(backing, compressed_workspace) or
        workspace.slices_overlap(backing, index_bytes))
    {
        return error.WorkspaceAliasing;
    }
    if (reader.backing_bytes) |input| {
        if (workspace.slices_overlap(backing, input)) return error.WorkspaceAliasing;
    }
}

test "apply limits reject configurations that cannot bound a database" {
    try (ApplyLimits{
        .max_database_pages = 1,
        .max_database_bytes = 512,
    }).validate();
    try std.testing.expectError(error.InvalidLimits, (ApplyLimits{
        .max_database_pages = 0,
        .max_database_bytes = 512,
    }).validate());
    try std.testing.expectError(error.InvalidLimits, (ApplyLimits{
        .max_database_pages = 1,
        .max_database_bytes = 0,
    }).validate());
}
