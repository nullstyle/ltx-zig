const std = @import("std");
const builtin = @import("builtin");
const ltx = @import("ltx");

pub const manifest_name = "ltx.current";
pub const manifest_temporary_name = "ltx.current.tmp";
pub const lock_name = "ltx.lock";
pub const database_a_name = "ltx.sqlite.a";
pub const database_b_name = "ltx.sqlite.b";

const manifest_size = 64;
const manifest_magic = "LTXSQL01";
const manifest_version: u32 = 1;
const manifest_magic_offset = 0;
const manifest_version_offset = 8;
const manifest_slot_offset = 12;
const manifest_empty_slot_tag: u8 = 2;
const manifest_reserved_a_offset = 13;
const manifest_generation_offset = 16;
const manifest_txid_offset = 24;
const manifest_position_checksum_offset = 32;
const manifest_page_size_offset = 40;
const manifest_reserved_b_offset = 44;
const manifest_database_size_offset = 48;
const manifest_digest_offset = 56;
const sqlite_magic = "SQLite format 3\x00";
const sqlite_uri_prefix = "file:";
const sqlite_uri_query = "?mode=ro&immutable=1";
const sqlite_query_only_sql: [:0]const u8 = "PRAGMA query_only=ON";
const sqlite_open_readonly: c_int = 0x0000_0001;
const sqlite_open_uri: c_int = 0x0000_0040;

pub const max_generation_path_bytes = std.Io.Dir.max_path_bytes;
pub const max_generation_uri_bytes = sqlite_uri_prefix.len +
    (max_generation_path_bytes - 1) * 3 + sqlite_uri_query.len + 1;

comptime {
    std.debug.assert(manifest_magic.len == 8);
    std.debug.assert(sqlite_magic.len == 16);
    std.debug.assert(manifest_digest_offset + @sizeOf(u64) == manifest_size);
    std.debug.assert(manifest_generation_offset - manifest_reserved_a_offset == 3);
    std.debug.assert(manifest_database_size_offset - manifest_reserved_b_offset == 4);
    std.debug.assert(max_generation_uri_bytes == 3 * std.Io.Dir.max_path_bytes + 23);
}

pub const Error = error{
    InvalidWorkspace,
    InvalidState,
    InvalidDatabasePath,
    UnsupportedPlatform,
    StoreBusy,
    QuiesceFailure,
    ManifestCorrupt,
    DatabaseMissing,
    DatabaseSizeMismatch,
    SidecarPresent,
    InvalidSQLiteDatabase,
    DatabasePageSizeMismatch,
    DatabaseChecksumMismatch,
    GenerationOverflow,
    FaultInjected,
    IOFailure,
};

/// Adapter-specific cause retained when a public store operation fails or an
/// `ApplyBackend` callback must collapse that cause into a generic `ltx` apply
/// error. The outer apply error still determines the failed phase and whether
/// recovery is mandatory; this value supplies only the SQLite-store cause.
/// Other than `none`, tags mirror `Error` one-for-one. See `Store.last_failure`
/// for reset and overwrite rules.
pub const Failure = enum {
    none,
    invalid_workspace,
    invalid_state,
    invalid_database_path,
    unsupported_platform,
    store_busy,
    quiesce_failure,
    manifest_corrupt,
    database_missing,
    database_size_mismatch,
    sidecar_present,
    invalid_sqlite_database,
    database_page_size_mismatch,
    database_checksum_mismatch,
    generation_overflow,
    fault_injected,
    io_failure,
};

/// Observable lifecycle of one `Store`.
pub const StoreState = enum {
    /// No stage, lifecycle gate, or exclusive store lock is retained. Public
    /// reads, generation acquisition, apply begin, and recovery may start.
    idle,
    /// The store is synchronously acquiring application quiescence and the
    /// exclusive store lock. Callbacks are non-reentrant, so callers normally
    /// cannot observe this transient state.
    acquiring,
    /// An `ApplyBackend.begin` succeeded and owns a private database stage.
    /// Publication or abort must end it.
    staging,
    /// Publication may have crossed its commit point, or recovery progressed
    /// past quiescence and then failed. Only `Store.recover` may advance this
    /// store; the lifecycle gate and possibly the exclusive lock remain held.
    recovery_required,
};

pub const Slot = enum(u8) {
    a = 0,
    b = 1,

    pub fn database_name(self: Slot) []const u8 {
        return switch (self) {
            .a => database_a_name,
            .b => database_b_name,
        };
    }

    fn other(self: Slot) Slot {
        return switch (self) {
            .a => .b,
            .b => .a,
        };
    }
};

/// The application must use this same gate for every SQLite open. `quiesce`
/// stops new opens, checkpoints and closes all owned connections, and returns
/// only after neither database generation has live SQLite users. `release` reopens
/// the gate; reopening a connection is the application's responsibility. The
/// operation is transactional: on `QuiesceFailure`, `quiesce` must restore
/// admission and retain no ownership that requires `release`, because the store
/// calls `release` only after a successful `quiesce`.
///
/// The host must hold its generation lease and open the active generation through
/// SQLite read-only (including `query_only`; WAL-header images also need the
/// `immutable=1` URI option) because no-checksum positions cannot detect
/// outside writes.
pub const Lifecycle = struct {
    context: *anyopaque,
    quiesce_fn: *const fn (context: *anyopaque) error{QuiesceFailure}!void,
    release_fn: *const fn (context: *anyopaque) void,
};

/// Testing-only, unstable durability boundaries exposed to deterministic crash
/// tests. These names are not part of the supported production API and may
/// change during any 0.x release.
pub const FaultPoint = enum {
    baseline_manifest_sync,
    baseline_directory_sync,
    baseline_manifest_rename,
    baseline_commit_directory_sync,
    loaded_manifest_directory_sync,
    database_sync,
    database_directory_sync,
    manifest_sync,
    manifest_directory_sync,
    manifest_rename,
    commit_directory_sync,
};

/// Testing-only, unstable fault injection for durability tests. `hit_fn` runs
/// at every boundary and may terminate the process. This type is outside the
/// supported production API and may change during any 0.x release. Production
/// callers must leave `Options.fault_injection` null.
pub const FaultInjection = struct {
    /// Compatibility controls retained for callers of the original test API.
    /// Prefer `fail_at` for new tests.
    fail_before_manifest_rename: bool = false,
    fail_after_manifest_rename: bool = false,
    fail_at: ?FaultPoint = null,
    context: ?*anyopaque = null,
    hit_fn: ?*const fn (context: ?*anyopaque, point: FaultPoint) void = null,
};

pub const Options = struct {
    /// Testing-only and unstable. Production callers must leave this null.
    fault_injection: ?*const FaultInjection = null,
};

pub const Current = struct {
    position: ltx.Position,
    page_size: u32,
    database_size_bytes: u64,
    generation: u64,
    slot: Slot,

    pub fn database_name(self: Current) []const u8 {
        return self.slot.database_name();
    }

    fn apply_current(self: Current) ltx.ApplyCurrent {
        return .{ .position = self.position, .page_size = self.page_size };
    }
};

/// Caller-owned, fixed-capacity scratch for resolving and encoding one active
/// generation. It must remain address-stable, exclusive, and live until the
/// corresponding `GenerationAccess.release` succeeds.
pub const GenerationAccessWorkspace = struct {
    path_bytes: [max_generation_path_bytes]u8 = undefined,
    uri_bytes: [max_generation_uri_bytes]u8 = undefined,
};

/// SQLite connection requirements carried by a held generation access. Hosts
/// may add threading flags, but must open the supplied URI with at least
/// `required_flags` and execute `query_only_sql` before exposing the connection.
pub const SQLiteOpenSpec = struct {
    uri: [:0]const u8,
    required_flags: c_int = sqlite_open_readonly | sqlite_open_uri,
    query_only_sql: [:0]const u8 = sqlite_query_only_sql,
};

const GenerationAccessPhase = enum { available, held };

/// Address-stable authority for one generation lease. Reusing storage after a
/// release is supported. The checked epoch makes copied, stale access handles
/// unable to inspect or release a later lease held by the same storage. Never
/// copy or move this storage while it is held. The `std.Io` provider and its
/// backing context must remain live until release succeeds.
pub const GenerationAccessStorage = struct {
    phase: GenerationAccessPhase = .available,
    epoch: u64 = 0,
    io: ?std.Io = null,
    lock_file: ?std.Io.File = null,
    current_value: ?Current = null,
    workspace: ?*GenerationAccessWorkspace = null,
    uri_length: usize = 0,
};

/// A lightweight handle to a manifest-selected generation protected by a
/// shared store lock. Copies share one authoritative storage record and are
/// invalidated together when the lease is released or its storage is reused.
/// Copy only for single-owner handoff, not for concurrent independent use.
pub const GenerationAccess = struct {
    storage: *GenerationAccessStorage,
    epoch: u64,

    pub fn current(self: *const GenerationAccess) Error!Current {
        const storage = try self.require_held();
        return storage.current_value orelse error.InvalidState;
    }

    pub fn sqlite_open_spec(self: *const GenerationAccess) Error!SQLiteOpenSpec {
        const storage = try self.require_held();
        const access_workspace = storage.workspace orelse return error.InvalidState;
        if (storage.uri_length >= access_workspace.uri_bytes.len) return error.InvalidState;
        return .{
            .uri = access_workspace.uri_bytes[0..storage.uri_length :0],
        };
    }

    /// Release only after every SQLite statement, BLOB, backup handle, and
    /// connection using this generation has closed. A stale or repeated
    /// release returns `InvalidState` without touching a possibly reused file
    /// descriptor.
    pub fn release(self: *GenerationAccess) Error!void {
        const storage = try self.require_held();
        const io = storage.io orelse return error.InvalidState;
        const file = storage.lock_file orelse return error.InvalidState;
        file.unlock(io);
        file.close(io);
        storage.lock_file = null;
        storage.current_value = null;
        storage.workspace = null;
        storage.uri_length = 0;
        storage.io = null;
        storage.phase = .available;
    }

    fn require_held(self: *const GenerationAccess) Error!*GenerationAccessStorage {
        if (self.storage.phase != .held or self.storage.epoch != self.epoch) {
            return error.InvalidState;
        }
        return self.storage;
    }
};

const Manifest = struct {
    /// Null is the canonical, durably initialized empty store.
    current: ?Current,

    fn encode(self: Manifest) [manifest_size]u8 {
        var bytes: [manifest_size]u8 = @splat(0);
        @memcpy(bytes[manifest_magic_offset..manifest_version_offset], manifest_magic);
        std.mem.writeInt(
            u32,
            bytes[manifest_version_offset..manifest_slot_offset],
            manifest_version,
            .big,
        );
        if (self.current) |current| {
            bytes[manifest_slot_offset] = @intFromEnum(current.slot);
            std.mem.writeInt(
                u64,
                bytes[manifest_generation_offset..manifest_txid_offset],
                current.generation,
                .big,
            );
            std.mem.writeInt(
                u64,
                bytes[manifest_txid_offset..manifest_position_checksum_offset],
                current.position.txid.value,
                .big,
            );
            std.mem.writeInt(
                u64,
                bytes[manifest_position_checksum_offset..manifest_page_size_offset],
                current.position.post_apply_checksum.value,
                .big,
            );
            std.mem.writeInt(
                u32,
                bytes[manifest_page_size_offset..manifest_reserved_b_offset],
                current.page_size,
                .big,
            );
            std.mem.writeInt(
                u64,
                bytes[manifest_database_size_offset..manifest_digest_offset],
                current.database_size_bytes,
                .big,
            );
        } else {
            bytes[manifest_slot_offset] = manifest_empty_slot_tag;
        }
        const digest = std.hash.crc.Crc64GoIso.hash(bytes[0..manifest_digest_offset]);
        std.mem.writeInt(u64, bytes[manifest_digest_offset..manifest_size], digest, .big);
        return bytes;
    }

    fn decode(bytes: *const [manifest_size]u8) Error!Manifest {
        if (!std.mem.eql(
            u8,
            bytes[manifest_magic_offset..manifest_version_offset],
            manifest_magic,
        )) return error.ManifestCorrupt;
        if (std.mem.readInt(
            u32,
            bytes[manifest_version_offset..manifest_slot_offset],
            .big,
        ) != manifest_version) {
            return error.ManifestCorrupt;
        }
        if (!std.mem.allEqual(
            u8,
            bytes[manifest_reserved_a_offset..manifest_generation_offset],
            0,
        ) or !std.mem.allEqual(
            u8,
            bytes[manifest_reserved_b_offset..manifest_database_size_offset],
            0,
        )) return error.ManifestCorrupt;
        const expected_digest = std.hash.crc.Crc64GoIso.hash(bytes[0..manifest_digest_offset]);
        if (std.mem.readInt(
            u64,
            bytes[manifest_digest_offset..manifest_size],
            .big,
        ) != expected_digest) {
            return error.ManifestCorrupt;
        }
        const slot: ?Slot = switch (bytes[manifest_slot_offset]) {
            0 => .a,
            1 => .b,
            manifest_empty_slot_tag => null,
            else => return error.ManifestCorrupt,
        };
        if (slot == null) {
            if (!std.mem.allEqual(
                u8,
                bytes[manifest_generation_offset..manifest_digest_offset],
                0,
            )) return error.ManifestCorrupt;
            return .{ .current = null };
        }
        const current: Current = .{
            .slot = slot.?,
            .generation = std.mem.readInt(
                u64,
                bytes[manifest_generation_offset..manifest_txid_offset],
                .big,
            ),
            .position = .{
                .txid = .init(std.mem.readInt(
                    u64,
                    bytes[manifest_txid_offset..manifest_position_checksum_offset],
                    .big,
                )),
                .post_apply_checksum = .init(std.mem.readInt(
                    u64,
                    bytes[manifest_position_checksum_offset..manifest_page_size_offset],
                    .big,
                )),
            },
            .page_size = std.mem.readInt(
                u32,
                bytes[manifest_page_size_offset..manifest_reserved_b_offset],
                .big,
            ),
            .database_size_bytes = std.mem.readInt(
                u64,
                bytes[manifest_database_size_offset..manifest_digest_offset],
                .big,
            ),
        };
        try validate_manifest_current(current);
        return .{ .current = current };
    }
};

test "manifest wire encoding is canonical and rejects reserved bytes" {
    const expected: Manifest = .{ .current = .{
        .position = .{
            .txid = .init(9),
            .post_apply_checksum = .init(ltx.checksum_flag | 0x1234),
        },
        .page_size = 512,
        .database_size_bytes = 1024,
        .generation = 7,
        .slot = .b,
    } };
    const canonical = expected.encode();
    try std.testing.expectEqualSlices(u8, manifest_magic, canonical[0..8]);
    try std.testing.expect(std.mem.allEqual(
        u8,
        canonical[manifest_reserved_a_offset..manifest_generation_offset],
        0,
    ));
    try std.testing.expectEqualDeep(expected, try Manifest.decode(&canonical));

    var noncanonical = canonical;
    noncanonical[manifest_reserved_a_offset] = 1;
    const digest = std.hash.crc.Crc64GoIso.hash(noncanonical[0..manifest_digest_offset]);
    std.mem.writeInt(
        u64,
        noncanonical[manifest_digest_offset..manifest_size],
        digest,
        .big,
    );
    try std.testing.expectError(error.ManifestCorrupt, Manifest.decode(&noncanonical));
}

test "manifest wire encoding has one canonical empty state" {
    const expected: Manifest = .{ .current = null };
    const canonical = expected.encode();
    try std.testing.expectEqual(manifest_empty_slot_tag, canonical[manifest_slot_offset]);
    try std.testing.expect(std.mem.allEqual(
        u8,
        canonical[manifest_generation_offset..manifest_digest_offset],
        0,
    ));
    try std.testing.expectEqualDeep(expected, try Manifest.decode(&canonical));

    var noncanonical = canonical;
    noncanonical[manifest_generation_offset] = 1;
    const digest = std.hash.crc.Crc64GoIso.hash(noncanonical[0..manifest_digest_offset]);
    std.mem.writeInt(
        u64,
        noncanonical[manifest_digest_offset..manifest_size],
        digest,
        .big,
    );
    try std.testing.expectError(error.ManifestCorrupt, Manifest.decode(&noncanonical));
}

test "SQLite generation URI encoding is canonical and delimiter-safe" {
    var destination: [max_generation_uri_bytes]u8 = undefined;
    const uri = try encode_sqlite_uri(
        "/tmp/space ?hash#percent%utf8\xc3\xa9.sqlite",
        &destination,
    );
    try std.testing.expectEqualStrings(
        "file:/tmp/space%20%3Fhash%23percent%25utf8%C3%A9.sqlite?mode=ro&immutable=1",
        uri,
    );
}

test "SQLite generation URI rejects ambiguous or non-UTF8 paths" {
    var destination: [max_generation_uri_bytes]u8 = undefined;
    const invalid_paths = [_][]const u8{
        "",
        "relative.sqlite",
        "//authority/database.sqlite",
        "/tmp/nul\x00database.sqlite",
        "/tmp/non-utf8-\xff.sqlite",
    };
    for (invalid_paths) |path| {
        try std.testing.expectError(
            error.InvalidDatabasePath,
            encode_sqlite_uri(path, &destination),
        );
    }
}

test "SQLite generation URI workspace covers the maximum valid path" {
    var path: [max_generation_path_bytes - 1]u8 = undefined;
    path[0] = '/';
    var index: usize = 1;
    while (index + 1 < path.len) : (index += 2) {
        path[index] = 0xc2;
        path[index + 1] = 0x80;
    }
    if (index < path.len) path[index] = 'a';
    var destination: [max_generation_uri_bytes]u8 = undefined;
    const uri = try encode_sqlite_uri(&path, &destination);
    try std.testing.expect(uri.len < destination.len);
    try std.testing.expectEqual(@as(u8, 0), destination[uri.len]);

    var overlong: [max_generation_path_bytes]u8 = @splat('a');
    overlong[0] = '/';
    try std.testing.expectError(
        error.InvalidDatabasePath,
        encode_sqlite_uri(&overlong, &destination),
    );
}

/// Allocation-free, quiescent two-generation SQLite storage. The directory is
/// borrowed; the `std.Io` provider, its backing context, and `copy_workspace`
/// must remain valid for the store's lifetime and until every generation access
/// releases. This is a stateful, single-owner value: never copy or concurrently
/// operate through copies after initialization.
pub const Store = struct {
    io: std.Io,
    dir: std.Io.Dir,
    copy_workspace: []u8,
    lifecycle: Lifecycle,
    options: Options,
    state: StoreState = .idle,
    gate_held: bool = false,
    lock_file: ?std.Io.File = null,
    stage_file: ?std.Io.File = null,
    captured_manifest: ?Manifest = null,
    stage_slot: Slot = .a,
    stage_plan: ?ltx.ApplyPlan = null,
    commit_crossed: bool = false,
    failure: Failure = .none,

    pub fn init(
        io: std.Io,
        dir: std.Io.Dir,
        copy_workspace: []u8,
        lifecycle: Lifecycle,
        options: Options,
    ) Error!Store {
        if (copy_workspace.len == 0) return error.InvalidWorkspace;
        switch (builtin.os.tag) {
            .linux, .macos => {},
            else => return error.UnsupportedPlatform,
        }
        return .{
            .io = io,
            .dir = dir,
            .copy_workspace = copy_workspace,
            .lifecycle = lifecycle,
            .options = options,
        };
    }

    /// Returns the storage-neutral adapter. Its callback error sets intentionally
    /// collapse platform causes; after a generic callback error, inspect
    /// `last_failure` before another operation can overwrite it. The outer
    /// `ltx` error remains authoritative for apply phase and recovery policy.
    pub fn backend(self: *Store) ltx.ApplyBackend {
        return .{
            .context = self,
            .begin_fn = begin_callback,
            .stage_page_fn = stage_page_callback,
            .read_page_fn = read_page_callback,
            .publish_fn = publish_callback,
            .abort_fn = abort_callback,
            .backing_bytes = self.copy_workspace,
        };
    }

    /// Returns the store lifecycle without changing `last_failure`. This is a
    /// diagnostic snapshot, not synchronization authority; the store remains
    /// single-owner and its callbacks remain non-reentrant.
    pub fn current_state(self: *const Store) StoreState {
        return self.state;
    }

    /// Returns the most recent SQLite-store cause. Failures from `current`,
    /// `acquire_generation`, `recover`, or a generic-failure adapter callback
    /// overwrite it. Successful `current`, `acquire_generation`, `recover`,
    /// apply begin, and publication clear it. Abort deliberately preserves the
    /// callback cause that triggered it. A failed recovery may replace an
    /// indeterminate-publication cause with the newer recovery cause, while
    /// successful recovery clears it.
    ///
    /// Generic `ltx` apply errors retain their own meaning: in particular,
    /// `ApplyPublishIndeterminate` requires `recover` regardless of this value.
    /// Read and snapshot this value before an operation that may record or
    /// clear it.
    pub fn last_failure(self: *const Store) Failure {
        return self.failure;
    }

    /// Reads the atomic pointer. It does not quiesce SQLite or inspect the
    /// database image; use `recover` when publication was indeterminate. A
    /// non-idle call returns `InvalidState` and records `invalid_state`.
    pub fn current(self: *Store) Error!?Current {
        try self.require_idle();
        self.acquire_lock(.shared) catch |err| return self.record(err);
        defer self.release_lock();
        const manifest = self.read_manifest() catch |err| return self.record(err);
        if (manifest == null) self.require_fresh_store() catch |err| return self.record(err);
        self.failure = .none;
        return if (manifest) |value| value.current else null;
    }

    /// Resolves the selected generation while acquiring a shared store lock.
    /// The returned access keeps that lock until `release`, so a cooperating
    /// writer cannot replace or reuse its slot. The host must close every
    /// SQLite resource using the generation before releasing the access. A
    /// non-idle call returns `InvalidState` and records `invalid_state`.
    pub fn acquire_generation(
        self: *Store,
        storage: *GenerationAccessStorage,
        access_workspace: *GenerationAccessWorkspace,
    ) Error!?GenerationAccess {
        try self.require_idle();
        self.validate_access_workspace(storage, access_workspace) catch |err|
            return self.record(err);
        if (storage.phase != .available) return self.record(error.InvalidState);
        const next_epoch = std.math.add(u64, storage.epoch, 1) catch
            return self.record(error.GenerationOverflow);

        const file = self.obtain_lock(.shared) catch |err| return self.record(err);
        var transferred = false;
        defer if (!transferred) {
            file.unlock(self.io);
            file.close(self.io);
        };
        const manifest = self.read_manifest() catch |err| return self.record(err);
        if (manifest == null) self.require_fresh_store() catch |err| return self.record(err);
        const current_value = if (manifest) |value| value.current else null;
        if (current_value == null) {
            self.failure = .none;
            return null;
        }
        self.validate_current_for_access(current_value.?) catch |err| return self.record(err);
        const path = self.resolve_generation_path(
            current_value.?,
            &access_workspace.path_bytes,
        ) catch |err| return self.record(err);
        const uri = encode_sqlite_uri(path, &access_workspace.uri_bytes) catch |err|
            return self.record(err);

        storage.phase = .held;
        storage.epoch = next_epoch;
        storage.io = self.io;
        storage.lock_file = file;
        storage.current_value = current_value.?;
        storage.workspace = access_workspace;
        storage.uri_length = uri.len;
        transferred = true;
        self.failure = .none;
        return .{ .storage = storage, .epoch = next_epoch };
    }

    /// Resolves an indeterminate commit by validating the manifest-selected
    /// generation under application quiescence. A stale pre-commit temporary
    /// manifest is discarded. Failure to acquire quiescence returns to `idle`.
    /// Every later failure retains `recovery_required` and any ownership already
    /// acquired, so the caller must repair the cause and retry on this same
    /// store. Success returns to `idle` and clears `last_failure`.
    pub fn recover(self: *Store) Error!?Current {
        switch (self.state) {
            .idle => {
                self.state = .acquiring;
                self.acquire_gate() catch |err| {
                    self.state = .idle;
                    return self.record(err);
                };
                self.state = .recovery_required;
            },
            .recovery_required => std.debug.assert(self.gate_held),
            else => return self.record(error.InvalidState),
        }
        if (self.lock_file == null) {
            self.acquire_lock(.exclusive) catch |err| return self.record(err);
        }
        self.reject_all_sidecars() catch |err| return self.record(err);
        const manifest = self.load_or_initialize_manifest() catch |err| return self.record(err);
        if (manifest.current) |current_value| {
            self.validate_current(current_value) catch |err| return self.record(err);
            _ = self.delete_temporary_manifest() catch |err| return self.record(err);
        } else {
            self.clean_empty_artifacts() catch |err| return self.record(err);
        }
        self.sync_directory() catch |err| return self.record(err);
        self.release_lock();
        self.release_gate();
        self.state = .idle;
        self.failure = .none;
        return manifest.current;
    }

    fn begin_callback(context: *anyopaque, plan: ltx.ApplyPlan) error{ApplyBeginFailure}!ltx.ApplyCurrent {
        const self: *Store = @ptrCast(@alignCast(context));
        return self.begin(plan) catch |err| {
            self.failure = failure_for_error(err);
            return error.ApplyBeginFailure;
        };
    }

    fn stage_page_callback(
        context: *anyopaque,
        page: ltx.StagedPage,
    ) error{ApplyStageFailure}!void {
        const self: *Store = @ptrCast(@alignCast(context));
        self.stage_page(page) catch |err| {
            self.failure = failure_for_error(err);
            return error.ApplyStageFailure;
        };
    }

    fn read_page_callback(
        context: *anyopaque,
        page_number: u32,
        destination: []u8,
    ) error{ApplyReadFailure}!void {
        const self: *Store = @ptrCast(@alignCast(context));
        self.read_page(page_number, destination) catch |err| {
            self.failure = failure_for_error(err);
            return error.ApplyReadFailure;
        };
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
        const self: *Store = @ptrCast(@alignCast(context));
        self.compare_expected(expected) catch |err| {
            if (err == error.ApplyPublishFailure) self.failure = .invalid_state;
            return err;
        };
        self.publish(verified) catch |err| {
            self.failure = failure_for_error(err);
            if (self.commit_crossed) {
                self.enter_recovery_required();
                return error.ApplyPublishIndeterminate;
            }
            return error.ApplyPublishFailure;
        };
    }

    fn abort_callback(context: *anyopaque) void {
        const self: *Store = @ptrCast(@alignCast(context));
        std.debug.assert(self.state == .staging);
        self.dir.deleteFile(self.io, manifest_temporary_name) catch {};
        if (self.captured_manifest) |manifest| {
            if (manifest.current == null) {
                self.dir.deleteFile(self.io, self.stage_slot.database_name()) catch {};
            }
        }
        self.finish_stage();
    }

    fn begin(self: *Store, plan: ltx.ApplyPlan) Error!ltx.ApplyCurrent {
        try self.require_idle();
        try validate_plan(plan);
        self.state = .acquiring;
        errdefer self.state = .idle;
        try self.acquire_gate();
        errdefer self.release_gate();
        try self.acquire_lock(.exclusive);
        errdefer self.release_lock();
        try self.reject_all_sidecars();
        const manifest = try self.load_or_initialize_manifest();
        if (!plan.header.is_snapshot() and manifest.current == null) return error.DatabaseMissing;
        if (manifest.current) |current_value| {
            try self.validate_current(current_value);
        } else {
            try self.clean_empty_artifacts();
            try self.sync_directory();
        }

        const slot: Slot = if (manifest.current) |current_value|
            current_value.slot.other()
        else
            .a;
        errdefer if (manifest.current == null) {
            self.dir.deleteFile(self.io, slot.database_name()) catch {};
        };
        const file = try self.create_stage(slot, manifest.current, plan);
        self.stage_file = file;
        self.captured_manifest = manifest;
        self.stage_slot = slot;
        self.stage_plan = plan;
        self.commit_crossed = false;
        self.state = .staging;
        self.failure = .none;
        return if (manifest.current) |current_value|
            current_value.apply_current()
        else
            empty_apply_current();
    }

    fn create_stage(
        self: *Store,
        slot: Slot,
        source_current: ?Current,
        plan: ltx.ApplyPlan,
    ) Error!std.Io.File {
        _ = try self.delete_path(slot.database_name());
        var destination = self.dir.createFile(self.io, slot.database_name(), .{
            .read = true,
            .truncate = false,
            .exclusive = true,
            .resolve_beneath = true,
        }) catch return error.IOFailure;
        errdefer destination.close(self.io);
        if (!plan.header.is_snapshot()) {
            const source_value = source_current orelse return error.DatabaseMissing;
            var source_file = self.dir.openFile(
                self.io,
                source_value.database_name(),
                .{
                    .mode = .read_only,
                    .allow_directory = false,
                    .follow_symlinks = false,
                    .resolve_beneath = true,
                },
            ) catch return error.DatabaseMissing;
            defer source_file.close(self.io);
            const copy_size_bytes = @min(
                source_value.database_size_bytes,
                plan.final_database_size_bytes,
            );
            try self.copy_exact(source_file, destination, copy_size_bytes);
        }
        destination.setLength(self.io, plan.final_database_size_bytes) catch return error.IOFailure;
        return destination;
    }

    fn copy_exact(
        self: *Store,
        source: std.Io.File,
        destination: std.Io.File,
        size_bytes: u64,
    ) Error!void {
        const chunk_bytes: u64 = @intCast(self.copy_workspace.len);
        const iteration_budget = size_bytes / chunk_bytes + @intFromBool(size_bytes % chunk_bytes != 0);
        var offset_bytes: u64 = 0;
        var iteration: u64 = 0;
        while (iteration < iteration_budget) : (iteration += 1) {
            const remaining_bytes = size_bytes - offset_bytes;
            const length: usize = @intCast(@min(remaining_bytes, chunk_bytes));
            const chunk = self.copy_workspace[0..length];
            const read = source.readPositionalAll(self.io, chunk, offset_bytes) catch return error.IOFailure;
            if (read != length) return error.DatabaseSizeMismatch;
            destination.writePositionalAll(self.io, chunk, offset_bytes) catch return error.IOFailure;
            offset_bytes += length;
        }
        if (offset_bytes != size_bytes) return error.DatabaseSizeMismatch;
    }

    fn stage_page(self: *Store, page: ltx.StagedPage) Error!void {
        const plan = self.stage_plan orelse return error.InvalidState;
        const file = self.stage_file orelse return error.InvalidState;
        if (self.state != .staging or page.page_number == 0) return error.InvalidState;
        if (page.data.len != plan.header.page_size) return error.InvalidState;
        const expected_offset = std.math.mul(
            u64,
            @as(u64, page.page_number - 1),
            plan.header.page_size,
        ) catch return error.InvalidState;
        if (page.offset_bytes != expected_offset) return error.InvalidState;
        const end_bytes = std.math.add(u64, page.offset_bytes, page.data.len) catch
            return error.InvalidState;
        if (end_bytes > plan.final_database_size_bytes) return error.InvalidState;
        file.writePositionalAll(self.io, page.data, page.offset_bytes) catch return error.IOFailure;
    }

    fn read_page(self: *Store, page_number: u32, destination: []u8) Error!void {
        const plan = self.stage_plan orelse return error.InvalidState;
        const file = self.stage_file orelse return error.InvalidState;
        if (self.state != .staging or page_number == 0) return error.InvalidState;
        if (destination.len != plan.header.page_size) return error.InvalidState;
        const page_index = @as(u64, page_number - 1);
        const offset_bytes = std.math.mul(u64, page_index, plan.header.page_size) catch
            return error.InvalidState;
        const end_bytes = std.math.add(u64, offset_bytes, destination.len) catch
            return error.InvalidState;
        if (end_bytes > plan.final_database_size_bytes) return error.InvalidState;
        const read = file.readPositionalAll(self.io, destination, offset_bytes) catch return error.IOFailure;
        if (read != destination.len) return error.DatabaseSizeMismatch;
    }

    fn compare_expected(self: *Store, expected: ltx.ApplyCurrent) error{
        ApplyPublishFailure,
        NonContiguousTransition,
        DivergentHistory,
        DatabasePageSizeMismatch,
    }!void {
        if (self.state != .staging) return error.ApplyPublishFailure;
        const manifest = self.captured_manifest orelse return error.ApplyPublishFailure;
        const actual = if (manifest.current) |current_value|
            current_value.apply_current()
        else
            empty_apply_current();
        if (expected.position.txid.value != actual.position.txid.value) {
            return error.NonContiguousTransition;
        }
        if (expected.position.post_apply_checksum.value !=
            actual.position.post_apply_checksum.value) return error.DivergentHistory;
        if (expected.page_size != actual.page_size) return error.DatabasePageSizeMismatch;
    }

    fn publish(self: *Store, verified: ltx.VerifiedLTX) Error!void {
        const plan = self.stage_plan orelse return error.InvalidState;
        const file = self.stage_file orelse return error.InvalidState;
        try self.validate_verified(plan, verified);
        try self.compare_manifest_on_disk();
        try self.reject_all_sidecars();
        try self.validate_sqlite_file(file, plan.header.page_size, plan.final_database_size_bytes);
        file.sync(self.io) catch return error.IOFailure;
        try self.hit_fault(.database_sync);
        try self.sync_directory();
        try self.hit_fault(.database_directory_sync);

        const captured = self.captured_manifest orelse return error.InvalidState;
        const generation = if (captured.current) |current_value|
            std.math.add(u64, current_value.generation, 1) catch return error.GenerationOverflow
        else
            1;
        const next: Manifest = .{ .current = .{
            .position = verified.post_apply_position(),
            .page_size = verified.header.page_size,
            .database_size_bytes = plan.final_database_size_bytes,
            .generation = generation,
            .slot = self.stage_slot,
        } };
        try validate_manifest_current(next.current.?);
        try self.write_temporary_manifest(next);
        try self.hit_fault(.manifest_sync);
        try self.sync_directory();
        try self.hit_fault(.manifest_directory_sync);
        self.dir.rename(
            manifest_temporary_name,
            self.dir,
            manifest_name,
            self.io,
        ) catch return error.IOFailure;
        self.commit_crossed = true;
        try self.hit_fault(.manifest_rename);
        try self.sync_directory();
        try self.hit_fault(.commit_directory_sync);
        self.finish_stage();
        self.failure = .none;
    }

    fn hit_fault(self: *const Store, point: FaultPoint) Error!void {
        const injection = self.options.fault_injection orelse return;
        if (injection.hit_fn) |hit_fn| hit_fn(injection.context, point);
        const legacy_failure = switch (point) {
            .manifest_directory_sync => injection.fail_before_manifest_rename,
            .manifest_rename => injection.fail_after_manifest_rename,
            else => false,
        };
        if (injection.fail_at == point or legacy_failure) return error.FaultInjected;
    }

    fn validate_verified(
        self: *Store,
        plan: ltx.ApplyPlan,
        verified: ltx.VerifiedLTX,
    ) Error!void {
        _ = self;
        if (verified.format_version != plan.format_version or
            !std.meta.eql(verified.header, plan.header))
        {
            return error.InvalidState;
        }
        const expected_size = std.math.mul(
            u64,
            verified.header.commit,
            verified.header.page_size,
        ) catch return error.InvalidState;
        if (expected_size != plan.final_database_size_bytes) return error.InvalidState;
        if (!verified.trailer.file_checksum.has_valid_flag()) return error.InvalidState;
        if (verified.header.no_checksum()) {
            if (verified.trailer.post_apply_checksum.value != 0) return error.InvalidState;
        } else if (!verified.trailer.post_apply_checksum.has_valid_flag()) {
            return error.InvalidState;
        }
    }

    fn compare_manifest_on_disk(self: *Store) Error!void {
        const actual = try self.read_manifest();
        if (!std.meta.eql(self.captured_manifest, actual)) return error.ManifestCorrupt;
    }

    fn write_temporary_manifest(self: *Store, manifest: Manifest) Error!void {
        _ = try self.delete_path(manifest_temporary_name);
        var file = self.dir.createFile(self.io, manifest_temporary_name, .{
            .read = false,
            .truncate = false,
            .exclusive = true,
            .resolve_beneath = true,
        }) catch return error.IOFailure;
        defer file.close(self.io);
        const bytes = manifest.encode();
        file.writePositionalAll(self.io, &bytes, 0) catch return error.IOFailure;
        file.sync(self.io) catch return error.IOFailure;
    }

    fn read_manifest(self: *Store) Error!?Manifest {
        var file = self.dir.openFile(
            self.io,
            manifest_name,
            .{
                .mode = .read_only,
                .allow_directory = false,
                .follow_symlinks = false,
                .resolve_beneath = true,
            },
        ) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return error.IOFailure,
        };
        defer file.close(self.io);
        const stat = file.stat(self.io) catch return error.IOFailure;
        if (stat.kind != .file or stat.size != manifest_size) return error.ManifestCorrupt;
        var bytes: [manifest_size]u8 = undefined;
        const read = file.readPositionalAll(self.io, &bytes, 0) catch return error.IOFailure;
        if (read != bytes.len) return error.ManifestCorrupt;
        return try Manifest.decode(&bytes);
    }

    /// Establishes the canonical empty manifest before any first-generation
    /// slot can be created. Missing current plus any slot remains ambiguous and
    /// fails closed; a temp-only state is an interrupted empty initialization.
    fn load_or_initialize_manifest(self: *Store) Error!Manifest {
        if (try self.read_manifest()) |manifest| {
            // A prior process may have exposed a manifest rename and exited
            // before syncing the directory. Make that observed selection
            // durable before begin is allowed to reuse the opposite slot.
            try self.sync_directory();
            try self.hit_fault(.loaded_manifest_directory_sync);
            return manifest;
        }
        if (try self.path_exists(database_a_name) or
            try self.path_exists(database_b_name))
        {
            return error.ManifestCorrupt;
        }

        _ = try self.delete_temporary_manifest();
        const baseline: Manifest = .{ .current = null };
        try self.write_temporary_manifest(baseline);
        try self.hit_fault(.baseline_manifest_sync);
        try self.sync_directory();
        try self.hit_fault(.baseline_directory_sync);
        self.dir.rename(
            manifest_temporary_name,
            self.dir,
            manifest_name,
            self.io,
        ) catch return error.IOFailure;
        try self.hit_fault(.baseline_manifest_rename);
        try self.sync_directory();
        try self.hit_fault(.baseline_commit_directory_sync);
        return baseline;
    }

    fn validate_access_workspace(
        self: *Store,
        storage: *GenerationAccessStorage,
        access_workspace: *GenerationAccessWorkspace,
    ) Error!void {
        const store_bytes = std.mem.asBytes(self);
        const storage_bytes = std.mem.asBytes(storage);
        const access_bytes = std.mem.asBytes(access_workspace);
        if (slices_overlap(store_bytes, storage_bytes) or
            slices_overlap(store_bytes, access_bytes) or
            slices_overlap(storage_bytes, access_bytes) or
            slices_overlap(self.copy_workspace, storage_bytes) or
            slices_overlap(self.copy_workspace, access_bytes) or
            slices_overlap(
                &access_workspace.path_bytes,
                &access_workspace.uri_bytes,
            ))
        {
            return error.InvalidWorkspace;
        }
    }

    fn validate_current_for_access(self: *Store, current_value: Current) Error!void {
        try self.reject_sidecars(current_value.slot);
        var file = self.dir.openFile(
            self.io,
            current_value.database_name(),
            .{
                .mode = .read_only,
                .allow_directory = false,
                .follow_symlinks = false,
                .resolve_beneath = true,
            },
        ) catch |err| return open_database_error(err);
        defer file.close(self.io);
        try self.validate_sqlite_file(
            file,
            current_value.page_size,
            current_value.database_size_bytes,
        );
    }

    fn resolve_generation_path(
        self: *Store,
        current_value: Current,
        path_workspace: *[max_generation_path_bytes]u8,
    ) Error![]const u8 {
        const name = current_value.database_name();
        const directory_length = self.dir.realPath(
            self.io,
            path_workspace,
        ) catch |err| switch (err) {
            error.NameTooLong => return error.InvalidDatabasePath,
            else => return error.IOFailure,
        };
        if (directory_length == 0 or directory_length >= path_workspace.len) {
            return error.InvalidDatabasePath;
        }
        const separator_length: usize = @intFromBool(
            path_workspace[directory_length - 1] != '/',
        );
        const name_offset = std.math.add(
            usize,
            directory_length,
            separator_length,
        ) catch return error.InvalidDatabasePath;
        const end = std.math.add(
            usize,
            name_offset,
            name.len,
        ) catch return error.InvalidDatabasePath;
        if (end >= path_workspace.len) return error.InvalidDatabasePath;
        if (separator_length == 1) path_workspace[directory_length] = '/';
        @memcpy(path_workspace[name_offset..end], name);
        path_workspace[end] = 0;
        return path_workspace[0..end];
    }

    fn validate_current(self: *Store, current_value: Current) Error!void {
        try self.reject_sidecars(current_value.slot);
        var file = self.dir.openFile(
            self.io,
            current_value.database_name(),
            .{
                .mode = .read_only,
                .allow_directory = false,
                .follow_symlinks = false,
                .resolve_beneath = true,
            },
        ) catch |err| return open_database_error(err);
        defer file.close(self.io);
        try self.validate_sqlite_file(
            file,
            current_value.page_size,
            current_value.database_size_bytes,
        );
        try self.verify_database_checksum(file, current_value);
    }

    fn validate_sqlite_file(
        self: *Store,
        file: std.Io.File,
        page_size: u32,
        size_bytes: u64,
    ) Error!void {
        const stat = file.stat(self.io) catch return error.IOFailure;
        if (stat.kind != .file or stat.size != size_bytes) return error.DatabaseSizeMismatch;
        if (size_bytes == 0) return;
        if (size_bytes < 100 or size_bytes % page_size != 0) {
            return error.InvalidSQLiteDatabase;
        }
        var header: [100]u8 = undefined;
        const read = file.readPositionalAll(self.io, &header, 0) catch return error.IOFailure;
        if (read != header.len or !std.mem.eql(u8, header[0..16], sqlite_magic)) {
            return error.InvalidSQLiteDatabase;
        }
        const encoded_page_size = std.mem.readInt(u16, header[16..18], .big);
        const actual_page_size: u32 = if (encoded_page_size == 1) 65_536 else encoded_page_size;
        if (actual_page_size != page_size) return error.DatabasePageSizeMismatch;
        if ((header[18] != 1 and header[18] != 2) or
            (header[19] != 1 and header[19] != 2) or
            header[21] != 64 or header[22] != 32 or header[23] != 32)
        {
            return error.InvalidSQLiteDatabase;
        }
        const reserved_bytes: u32 = header[20];
        if (page_size - reserved_bytes < 480) return error.InvalidSQLiteDatabase;
        const change_counter = std.mem.readInt(u32, header[24..28], .big);
        const header_page_count = std.mem.readInt(u32, header[28..32], .big);
        const version_valid_for = std.mem.readInt(u32, header[92..96], .big);
        const physical_page_count = size_bytes / page_size;
        if (header_page_count != 0 and change_counter == version_valid_for and
            header_page_count != physical_page_count)
        {
            return error.InvalidSQLiteDatabase;
        }
    }

    fn verify_database_checksum(
        self: *Store,
        file: std.Io.File,
        current_value: Current,
    ) Error!void {
        const expected = current_value.position.post_apply_checksum;
        if (expected.value == 0) return;
        const page_count_u64 = current_value.database_size_bytes / current_value.page_size;
        const page_count: u32 = @intCast(page_count_u64);
        const lock_page = ltx.lock_page_number(current_value.page_size) catch
            return error.ManifestCorrupt;
        var rolling = ltx.rolling_checksum_initial();
        var page_index: u32 = 0;
        while (page_index < page_count) : (page_index += 1) {
            const page_number = page_index + 1;
            if (page_number == lock_page) continue;
            const page_checksum = try self.checksum_file_page(
                file,
                page_number,
                current_value.page_size,
            );
            rolling = ltx.rolling_checksum_add(rolling, page_checksum) catch
                return error.ManifestCorrupt;
        }
        if (rolling.value != expected.value) return error.DatabaseChecksumMismatch;
    }

    fn checksum_file_page(
        self: *Store,
        file: std.Io.File,
        page_number: u32,
        page_size: u32,
    ) Error!ltx.Checksum {
        var page_number_bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &page_number_bytes, page_number, .big);
        var crc = std.hash.crc.Crc64GoIso.init();
        crc.update(&page_number_bytes);
        const chunk_bytes: u64 = @intCast(self.copy_workspace.len);
        const budget = @as(u64, page_size) / chunk_bytes +
            @intFromBool(@as(u64, page_size) % chunk_bytes != 0);
        var offset_in_page: u64 = 0;
        var iteration: u64 = 0;
        while (iteration < budget) : (iteration += 1) {
            const remaining = @as(u64, page_size) - offset_in_page;
            const length: usize = @intCast(@min(remaining, chunk_bytes));
            const chunk = self.copy_workspace[0..length];
            const page_offset = @as(u64, page_number - 1) * page_size;
            const read = file.readPositionalAll(
                self.io,
                chunk,
                page_offset + offset_in_page,
            ) catch return error.IOFailure;
            if (read != length) return error.DatabaseSizeMismatch;
            crc.update(chunk);
            offset_in_page += length;
        }
        return .init(ltx.checksum_flag | crc.final());
    }

    fn reject_all_sidecars(self: *Store) Error!void {
        try self.reject_sidecars(.a);
        try self.reject_sidecars(.b);
    }

    fn reject_sidecars(self: *Store, slot: Slot) Error!void {
        switch (slot) {
            .a => {
                try self.reject_existing("ltx.sqlite.a-wal");
                try self.reject_existing("ltx.sqlite.a-shm");
                try self.reject_existing("ltx.sqlite.a-journal");
            },
            .b => {
                try self.reject_existing("ltx.sqlite.b-wal");
                try self.reject_existing("ltx.sqlite.b-shm");
                try self.reject_existing("ltx.sqlite.b-journal");
            },
        }
    }

    fn reject_existing(self: *Store, name: []const u8) Error!void {
        if (try self.path_exists(name)) return error.SidecarPresent;
    }

    fn acquire_lock(self: *Store, lock: std.Io.File.Lock) Error!void {
        std.debug.assert(self.lock_file == null);
        self.lock_file = try self.obtain_lock(lock);
    }

    fn obtain_lock(self: *Store, lock: std.Io.File.Lock) Error!std.Io.File {
        var attempt: u8 = 0;
        while (attempt < 2) : (attempt += 1) {
            return self.open_or_create_lock(lock) catch |err| switch (err) {
                error.PathAlreadyExists, error.FileNotFound => continue,
                error.WouldBlock => return error.StoreBusy,
                else => return error.IOFailure,
            };
        }
        return error.StoreBusy;
    }

    fn open_or_create_lock(
        self: *Store,
        lock: std.Io.File.Lock,
    ) std.Io.File.OpenError!std.Io.File {
        return self.dir.openFile(self.io, lock_name, .{
            .mode = .read_only,
            .allow_directory = false,
            .lock = lock,
            .lock_nonblocking = true,
            .follow_symlinks = false,
            .resolve_beneath = true,
        }) catch |err| switch (err) {
            error.FileNotFound => self.dir.createFile(self.io, lock_name, .{
                .read = true,
                .truncate = false,
                .exclusive = true,
                .lock = lock,
                .lock_nonblocking = true,
                .resolve_beneath = true,
            }),
            else => return err,
        };
    }

    fn release_lock(self: *Store) void {
        const file = self.lock_file orelse return;
        file.unlock(self.io);
        file.close(self.io);
        self.lock_file = null;
    }

    fn acquire_gate(self: *Store) Error!void {
        std.debug.assert(!self.gate_held);
        self.lifecycle.quiesce_fn(self.lifecycle.context) catch
            return error.QuiesceFailure;
        self.gate_held = true;
    }

    fn release_gate(self: *Store) void {
        if (!self.gate_held) return;
        self.lifecycle.release_fn(self.lifecycle.context);
        self.gate_held = false;
    }

    fn finish_stage(self: *Store) void {
        if (self.stage_file) |file| file.close(self.io);
        self.stage_file = null;
        self.captured_manifest = null;
        self.stage_plan = null;
        self.commit_crossed = false;
        self.release_lock();
        self.release_gate();
        self.state = .idle;
    }

    fn enter_recovery_required(self: *Store) void {
        std.debug.assert(self.gate_held and self.commit_crossed and self.lock_file != null);
        if (self.stage_file) |file| file.close(self.io);
        self.stage_file = null;
        self.captured_manifest = null;
        self.stage_plan = null;
        self.commit_crossed = false;
        self.state = .recovery_required;
    }

    fn delete_temporary_manifest(self: *Store) Error!bool {
        self.dir.deleteFile(self.io, manifest_temporary_name) catch |err| switch (err) {
            error.FileNotFound => return false,
            else => return error.IOFailure,
        };
        return true;
    }

    fn clean_empty_artifacts(self: *Store) Error!void {
        _ = try self.delete_path(database_a_name);
        _ = try self.delete_path(database_b_name);
        _ = try self.delete_temporary_manifest();
    }

    fn require_fresh_store(self: *Store) Error!void {
        if (try self.path_exists(database_a_name) or
            try self.path_exists(database_b_name) or
            try self.path_exists(manifest_temporary_name))
        {
            return error.ManifestCorrupt;
        }
    }

    fn path_exists(self: *Store, name: []const u8) Error!bool {
        _ = self.dir.statFile(self.io, name, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => return false,
            else => return error.IOFailure,
        };
        return true;
    }

    fn delete_path(self: *Store, name: []const u8) Error!bool {
        self.dir.deleteFile(self.io, name) catch |err| switch (err) {
            error.FileNotFound => return false,
            else => return error.IOFailure,
        };
        return true;
    }

    fn sync_directory(self: *Store) Error!void {
        // A non-iterable `Dir` may hold an `O_PATH` descriptor on Linux, which
        // cannot be synced. Reopen the same directory as a syncable file.
        var file = self.dir.openFile(self.io, ".", .{
            .mode = .read_only,
            .allow_directory = true,
            .follow_symlinks = false,
            .resolve_beneath = true,
        }) catch return error.IOFailure;
        defer file.close(self.io);
        file.sync(self.io) catch return error.IOFailure;
    }

    fn require_idle(self: *Store) Error!void {
        if (self.state != .idle) return self.record(error.InvalidState);
    }

    fn record(self: *Store, err: Error) Error {
        self.failure = failure_for_error(err);
        return err;
    }
};

fn empty_apply_current() ltx.ApplyCurrent {
    return .{
        .position = .{ .txid = .init(0), .post_apply_checksum = .init(0) },
        .page_size = null,
    };
}

fn encode_sqlite_uri(
    path: []const u8,
    destination: *[max_generation_uri_bytes]u8,
) Error![:0]const u8 {
    try validate_database_path(path);
    var encoded_path_bytes: usize = 0;
    var path_index: usize = 0;
    while (path_index < path.len) : (path_index += 1) {
        encoded_path_bytes += if (is_uri_path_byte(path[path_index])) 1 else 3;
    }
    const suffix_bytes = sqlite_uri_query.len + 1;
    const required_bytes = std.math.add(
        usize,
        sqlite_uri_prefix.len + encoded_path_bytes,
        suffix_bytes,
    ) catch return error.InvalidDatabasePath;
    if (required_bytes > destination.len) return error.InvalidDatabasePath;

    @memcpy(destination[0..sqlite_uri_prefix.len], sqlite_uri_prefix);
    var output_index = sqlite_uri_prefix.len;
    path_index = 0;
    while (path_index < path.len) : (path_index += 1) {
        const byte = path[path_index];
        if (is_uri_path_byte(byte)) {
            destination[output_index] = byte;
            output_index += 1;
        } else {
            destination[output_index] = '%';
            destination[output_index + 1] = uri_hex[byte >> 4];
            destination[output_index + 2] = uri_hex[byte & 0x0f];
            output_index += 3;
        }
    }
    @memcpy(destination[output_index .. output_index + sqlite_uri_query.len], sqlite_uri_query);
    output_index += sqlite_uri_query.len;
    destination[output_index] = 0;
    return destination[0..output_index :0];
}

fn validate_database_path(path: []const u8) Error!void {
    if (path.len == 0 or path.len >= max_generation_path_bytes) {
        return error.InvalidDatabasePath;
    }
    if (path[0] != '/' or (path.len > 1 and path[1] == '/')) {
        return error.InvalidDatabasePath;
    }
    if (std.mem.indexOfScalar(u8, path, 0) != null or
        !std.unicode.utf8ValidateSlice(path))
    {
        return error.InvalidDatabasePath;
    }
}

const uri_hex = "0123456789ABCDEF";

fn is_uri_path_byte(byte: u8) bool {
    return switch (byte) {
        'a'...'z', 'A'...'Z', '0'...'9', '-', '.', '_', '~', '/' => true,
        else => false,
    };
}

fn slices_overlap(left: []const u8, right: []const u8) bool {
    if (left.len == 0 or right.len == 0) return false;
    const left_start = @intFromPtr(left.ptr);
    const right_start = @intFromPtr(right.ptr);
    const left_end = std.math.add(usize, left_start, left.len) catch unreachable;
    const right_end = std.math.add(usize, right_start, right.len) catch unreachable;
    return left_start < right_end and right_start < left_end;
}

fn validate_plan(plan: ltx.ApplyPlan) Error!void {
    switch (plan.format_version) {
        .v2, .v3 => {},
        _ => return error.InvalidState,
    }
    if (!valid_page_size(plan.header.page_size)) {
        return error.InvalidState;
    }
    const expected_size = std.math.mul(
        u64,
        plan.header.commit,
        plan.header.page_size,
    ) catch return error.InvalidState;
    if (expected_size != plan.final_database_size_bytes) return error.InvalidState;
}

fn validate_manifest_current(current: Current) Error!void {
    if (current.generation == 0 or current.position.txid.value == 0) {
        return error.ManifestCorrupt;
    }
    if (!valid_page_size(current.page_size)) return error.ManifestCorrupt;
    if (current.database_size_bytes % current.page_size != 0) return error.ManifestCorrupt;
    if (current.database_size_bytes / current.page_size > std.math.maxInt(u32)) {
        return error.ManifestCorrupt;
    }
    const checksum = current.position.post_apply_checksum.value;
    if (checksum != 0 and checksum & (@as(u64, 1) << 63) == 0) {
        return error.ManifestCorrupt;
    }
}

fn valid_page_size(page_size: u32) bool {
    return page_size >= 512 and page_size <= 65_536 and std.math.isPowerOfTwo(page_size);
}

fn open_database_error(err: std.Io.File.OpenError) Error {
    return switch (err) {
        error.FileNotFound => error.DatabaseMissing,
        else => error.IOFailure,
    };
}

fn failure_for_error(err: Error) Failure {
    return switch (err) {
        error.InvalidWorkspace => .invalid_workspace,
        error.InvalidState => .invalid_state,
        error.InvalidDatabasePath => .invalid_database_path,
        error.UnsupportedPlatform => .unsupported_platform,
        error.StoreBusy => .store_busy,
        error.QuiesceFailure => .quiesce_failure,
        error.ManifestCorrupt => .manifest_corrupt,
        error.DatabaseMissing => .database_missing,
        error.DatabaseSizeMismatch => .database_size_mismatch,
        error.SidecarPresent => .sidecar_present,
        error.InvalidSQLiteDatabase => .invalid_sqlite_database,
        error.DatabasePageSizeMismatch => .database_page_size_mismatch,
        error.DatabaseChecksumMismatch => .database_checksum_mismatch,
        error.GenerationOverflow => .generation_overflow,
        error.FaultInjected => .fault_injected,
        error.IOFailure => .io_failure,
    };
}
