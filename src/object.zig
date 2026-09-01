//! Storage-neutral LTX object access.
//!
//! The `Client` contract mirrors the storage half of the pinned Celld crate's
//! `ReplicaClient` trait: listings ascending by TXID range, exact bounded
//! generation-bound range reads, idempotent writes, and idempotent deletes —
//! all over
//! caller-owned buffers, with no allocation inside this module. Objects are
//! opaque byte blobs at this layer; only their level and TXID-range identity
//! are interpreted here, while listings also report their exact stored length.
//!
//! `FileClient` implements the contract over a directory handle using the
//! Litestream filesystem replica layout (`<root>/ltx/<level>/<min>-<max>.ltx`)
//! with write-to-temp-then-rename publication. `run_conformance` is a
//! backend-agnostic suite every implementation must pass against empty
//! storage.

const std = @import("std");
const ltx = @import("ltx");

pub const Error = error{
    InvalidLevel,
    InvalidIdentity,
    InvalidReadRange,
    InvalidTimestamp,
    ObjectNotFound,
    ObjectExists,
    /// The stored object no longer has the listed size or generation.
    ObjectChanged,
    /// An adapter could not supply a stable, nonempty read generation.
    GenerationUnavailable,
    /// An adapter's generation token exceeds the fixed receipt capacity.
    GenerationTooLarge,
    /// A conditional replace saw a different stored generation than the
    /// caller expected; the caller must re-read and decide.
    ETagMismatch,
    InvalidState,
    ObjectTooLarge,
    StorageFailure,
    /// Publication crossed the adapter's commit point, but the adapter could
    /// not confirm the durable result. The caller must reconcile the object.
    PublicationIndeterminate,
    ListingCapacityExceeded,
    ListingPageLimitExceeded,
    PathTooLong,
    ConformanceFailure,
    WriteSessionUnsupported,
    StagingCapacityExceeded,
    ReadWorkspaceTooSmall,
};

pub const max_read_generation_bytes: usize = 128;

/// One fixed-capacity, pointer-free receipt identifying the object generation
/// that supplied a range. Adapter tokens are opaque to callers, but must be
/// nonempty and stable for the lifetime of that stored generation.
pub const ReadGeneration = struct {
    bytes: [max_read_generation_bytes]u8 = undefined,
    length_bytes: u8,

    pub fn init(value_bytes: []const u8) Error!ReadGeneration {
        if (value_bytes.len == 0) return error.GenerationUnavailable;
        if (value_bytes.len > max_read_generation_bytes) {
            return error.GenerationTooLarge;
        }
        var receipt = ReadGeneration{ .length_bytes = @intCast(value_bytes.len) };
        @memcpy(receipt.bytes[0..value_bytes.len], value_bytes);
        return receipt;
    }

    pub fn value(self: *const ReadGeneration) []const u8 {
        std.debug.assert(self.length_bytes != 0);
        std.debug.assert(self.length_bytes <= max_read_generation_bytes);
        return self.bytes[0..self.length_bytes];
    }

    pub fn eql(self: ReadGeneration, other: ReadGeneration) bool {
        return std.mem.eql(u8, self.value(), other.value());
    }

    fn validate(self: ReadGeneration) Error!void {
        if (self.length_bytes == 0) return error.GenerationUnavailable;
        if (self.length_bytes > max_read_generation_bytes) {
            return error.GenerationTooLarge;
        }
    }
};

pub const WriteSessionState = enum {
    open,
    failed,
    final,
};

/// Adapter operations hidden behind one transactional write session. `write`
/// only appends to private staging. `finish` is the sole publication attempt;
/// `abort` infallibly ends the session and best-effort discards private state.
pub const WriteSessionBackend = struct {
    context: *anyopaque,
    write_fn: *const fn (context: *anyopaque, bytes: []const u8) Error!void,
    finish_fn: *const fn (context: *anyopaque) Error!void,
    abort_fn: *const fn (context: *anyopaque) void,
};

/// A single-owner transactional object writer. Keep the value at a stable
/// address while its `ltx.Writer` is in use, and never copy it after the first
/// operation. A backend write or finish error poisons the session and aborts
/// private staging. Only successful `finish` establishes trusted publication;
/// `PublicationIndeterminate` means the adapter crossed its commit point and
/// the caller must reconcile the object before advancing durable state.
pub const WriteSession = struct {
    backend: WriteSessionBackend,
    state: WriteSessionState = .open,

    pub fn init(backend: WriteSessionBackend) WriteSession {
        return .{ .backend = backend };
    }

    pub fn writer(self: *WriteSession) ltx.Writer {
        return .{
            .context = self,
            .write_all_fn = write_all,
        };
    }

    pub fn current_state(self: *const WriteSession) WriteSessionState {
        return self.state;
    }

    pub fn finish(self: *WriteSession) Error!void {
        if (self.state != .open) return error.InvalidState;
        self.backend.finish_fn(self.backend.context) catch |err| {
            self.fail();
            return err;
        };
        self.state = .final;
    }

    pub fn abort(self: *WriteSession) void {
        if (self.state != .open) return;
        self.state = .final;
        self.backend.abort_fn(self.backend.context);
    }

    fn write_all(context: *anyopaque, bytes: []const u8) error{OutputFailure}!void {
        const self: *WriteSession = @ptrCast(@alignCast(context));
        if (self.state != .open) return error.OutputFailure;
        self.backend.write_fn(self.backend.context, bytes) catch {
            self.fail();
            return error.OutputFailure;
        };
    }

    fn fail(self: *WriteSession) void {
        std.debug.assert(self.state == .open);
        self.state = .failed;
        self.backend.abort_fn(self.backend.context);
    }
};

/// One LTX object store. Callbacks must be synchronous and non-reentrant.
/// All variable-size results are written into caller-owned storage.
pub const Client = struct {
    context: *anyopaque,
    /// Lists the level's objects ascending by `(min_txid, max_txid)`,
    /// including only objects whose minimum TXID is at least `seek`. Every
    /// returned entry reports the exact stored object size. Returns the filled
    /// prefix of `destination`.
    list_fn: *const fn (
        context: *anyopaque,
        level: u8,
        seek: ltx.TXID,
        destination: []ltx.FileInfo,
    ) Error![]const ltx.FileInfo,
    /// Fills one exact range from a listed object and returns the generation
    /// that supplied it. When `expected_generation` is non-null, the adapter
    /// must reject any other generation before exposing successful bytes. It
    /// must also reject a current stored length different from
    /// `info.size_bytes`; successful short reads are forbidden.
    read_range_fn: *const fn (
        context: *anyopaque,
        info: ltx.FileInfo,
        expected_generation: ?ReadGeneration,
        offset_bytes: u64,
        destination: []u8,
    ) Error!ReadGeneration,
    /// Writes one object at the identity's key. Overwrites are idempotent.
    /// `created_at_ms` is the creation timestamp the backend should report
    /// in listings when it supports object metadata.
    write_fn: *const fn (
        context: *anyopaque,
        level: u8,
        identity: ltx.FileIdentity,
        created_at_ms: i64,
        bytes: []const u8,
    ) Error!void,
    /// Starts an optional transactional streaming write. The returned session
    /// owns private staging until it finishes, aborts, or fails.
    begin_write_fn: ?*const fn (
        context: *anyopaque,
        level: u8,
        identity: ltx.FileIdentity,
        created_at_ms: i64,
    ) Error!WriteSession = null,
    /// Deletes objects; missing ones are ignored.
    delete_fn: *const fn (
        context: *anyopaque,
        files: []const ltx.FileInfo,
    ) Error!void,

    pub fn list(
        self: Client,
        level: u8,
        seek: ltx.TXID,
        destination: []ltx.FileInfo,
    ) Error![]const ltx.FileInfo {
        if (level > ltx.max_level) return error.InvalidLevel;
        return self.list_fn(self.context, level, seek, destination);
    }

    pub fn read_range(
        self: Client,
        info: ltx.FileInfo,
        offset_bytes: u64,
        destination: []u8,
    ) Error!void {
        var generation: ?ReadGeneration = null;
        try self.read_range_bound(
            info,
            &generation,
            offset_bytes,
            destination,
        );
    }

    fn read_range_bound(
        self: Client,
        info: ltx.FileInfo,
        generation: *?ReadGeneration,
        offset_bytes: u64,
        destination: []u8,
    ) Error!void {
        try validate_file_info(info);
        const count_bytes = std.math.cast(u64, destination.len) orelse
            return error.InvalidReadRange;
        const end_bytes = std.math.add(u64, offset_bytes, count_bytes) catch
            return error.InvalidReadRange;
        if (end_bytes > info.size_bytes) return error.InvalidReadRange;
        if (destination.len == 0) return;
        const returned = try self.read_range_fn(
            self.context,
            info,
            generation.*,
            offset_bytes,
            destination,
        );
        try returned.validate();
        if (generation.*) |expected| {
            if (!expected.eql(returned)) return error.ObjectChanged;
        } else {
            generation.* = returned;
        }
    }

    /// Reads one complete listed object through the range seam. The returned
    /// slice occupies exactly `info.size_bytes` bytes of `destination`.
    pub fn read_all(
        self: Client,
        info: ltx.FileInfo,
        destination: []u8,
    ) Error![]const u8 {
        try validate_file_info(info);
        const size_bytes = std.math.cast(usize, info.size_bytes) orelse
            return error.ObjectTooLarge;
        if (size_bytes > destination.len) return error.ObjectTooLarge;
        try self.read_range(info, 0, destination[0..size_bytes]);
        return destination[0..size_bytes];
    }

    pub fn write(
        self: Client,
        level: u8,
        identity: ltx.FileIdentity,
        created_at_ms: i64,
        bytes: []const u8,
    ) Error!void {
        if (level > ltx.max_level) return error.InvalidLevel;
        if (identity.min_txid.value > identity.max_txid.value) {
            return error.InvalidIdentity;
        }
        return self.write_fn(self.context, level, identity, created_at_ms, bytes);
    }

    pub fn begin_write(
        self: Client,
        level: u8,
        identity: ltx.FileIdentity,
        created_at_ms: i64,
    ) Error!WriteSession {
        if (level > ltx.max_level) return error.InvalidLevel;
        if (identity.min_txid.value > identity.max_txid.value) {
            return error.InvalidIdentity;
        }
        const begin = self.begin_write_fn orelse return error.WriteSessionUnsupported;
        return begin(self.context, level, identity, created_at_ms);
    }

    /// Reports whether `begin_write` has an adapter implementation.
    pub fn supports_write_sessions(self: Client) bool {
        return self.begin_write_fn != null;
    }

    pub fn delete(self: Client, files: []const ltx.FileInfo) Error!void {
        return self.delete_fn(self.context, files);
    }
};

/// A bounded sequential view over one listed object. `self`, its workspace,
/// and the client context must stay at stable, non-overlapping addresses while
/// the derived `ltx.Reader` is in use. A range failure poisons the reader and
/// remains available through `failure()` after the transport narrows it to
/// `InputFailure`.
pub const ObjectReader = struct {
    client: Client,
    info: ltx.FileInfo,
    workspace: []u8,
    object_offset_bytes: u64 = 0,
    buffered_offset_bytes: usize = 0,
    buffered_length_bytes: usize = 0,
    generation: ?ReadGeneration = null,
    failure_value: ?Error = null,

    pub fn init(
        client: Client,
        info: ltx.FileInfo,
        workspace: []u8,
    ) Error!ObjectReader {
        try validate_file_info(info);
        if (workspace.len == 0) return error.ReadWorkspaceTooSmall;
        return .{
            .client = client,
            .info = info,
            .workspace = workspace,
        };
    }

    pub fn reader(self: *ObjectReader) ltx.Reader {
        return .{
            .context = self,
            .read_fn = read,
            .at_end_fn = at_end,
            .backing_bytes = self.workspace,
            .backing_is_mutable = true,
        };
    }

    pub fn failure(self: *const ObjectReader) ?Error {
        return self.failure_value;
    }

    fn read(context: *anyopaque, destination: []u8) error{InputFailure}!usize {
        const self: *ObjectReader = @ptrCast(@alignCast(context));
        if (self.failure_value != null) return error.InputFailure;
        if (destination.len == 0 or self.object_offset_bytes == self.info.size_bytes) {
            return 0;
        }
        if (self.buffered_offset_bytes == self.buffered_length_bytes) {
            self.refill() catch |err| {
                self.failure_value = err;
                return error.InputFailure;
            };
        }
        const available_bytes = self.buffered_length_bytes - self.buffered_offset_bytes;
        const count_bytes = @min(destination.len, available_bytes);
        @memcpy(
            destination[0..count_bytes],
            self.workspace[self.buffered_offset_bytes..][0..count_bytes],
        );
        self.buffered_offset_bytes += count_bytes;
        self.object_offset_bytes = std.math.add(
            u64,
            self.object_offset_bytes,
            @intCast(count_bytes),
        ) catch unreachable;
        std.debug.assert(self.object_offset_bytes <= self.info.size_bytes);
        return count_bytes;
    }

    fn at_end(context: *anyopaque) error{InputFailure}!bool {
        const self: *ObjectReader = @ptrCast(@alignCast(context));
        if (self.failure_value != null) return error.InputFailure;
        return self.object_offset_bytes == self.info.size_bytes;
    }

    fn refill(self: *ObjectReader) Error!void {
        std.debug.assert(self.failure_value == null);
        std.debug.assert(self.buffered_offset_bytes == self.buffered_length_bytes);
        std.debug.assert(self.object_offset_bytes < self.info.size_bytes);
        const remaining_bytes = self.info.size_bytes - self.object_offset_bytes;
        const workspace_bytes = std.math.cast(u64, self.workspace.len) orelse
            return error.InvalidReadRange;
        const request_bytes: usize = @intCast(@min(remaining_bytes, workspace_bytes));
        try self.client.read_range_bound(
            self.info,
            &self.generation,
            self.object_offset_bytes,
            self.workspace[0..request_bytes],
        );
        self.buffered_offset_bytes = 0;
        self.buffered_length_bytes = request_bytes;
    }
};

fn validate_file_info(info: ltx.FileInfo) Error!void {
    if (info.level > ltx.max_level) return error.InvalidLevel;
    if (info.min_txid.value > info.max_txid.value) return error.InvalidIdentity;
    if (info.size_bytes == 0) return error.InvalidReadRange;
}

/// Filesystem-backed `Client` using the Litestream replica layout under one
/// directory handle. The value is stateful and single-owner: keep it at a
/// stable address while the derived `Client` is in use.
pub const FileClient = struct {
    dir: std.Io.Dir,
    io: std.Io,
    root: [std.Io.Dir.max_path_bytes]u8 = undefined,
    root_bytes: usize,
    path_a: [std.Io.Dir.max_path_bytes]u8 = undefined,
    path_b: [std.Io.Dir.max_path_bytes]u8 = undefined,
    write_final_path: [std.Io.Dir.max_path_bytes]u8 = undefined,
    write_final_path_bytes: usize = 0,
    write_temporary_path: [std.Io.Dir.max_path_bytes]u8 = undefined,
    write_temporary_path_bytes: usize = 0,
    write_session_file: ?std.Io.File = null,
    write_offset_bytes: u64 = 0,
    write_session_active: bool = false,
    level_directories_synced: [@as(usize, ltx.max_level) + 1]bool = @splat(false),

    /// `root` is the subpath under `dir` that holds the replica; empty means
    /// `dir` itself. It must be a clean relative path without a trailing
    /// slash.
    pub fn init(dir: std.Io.Dir, io: std.Io, root: []const u8) Error!FileClient {
        if (root.len > std.Io.Dir.max_path_bytes) return error.PathTooLong;
        var self = FileClient{
            .dir = dir,
            .io = io,
            .root_bytes = root.len,
        };
        @memcpy(self.root[0..root.len], root);
        return self;
    }

    pub fn client(self: *FileClient) Client {
        return .{
            .context = self,
            .list_fn = list,
            .read_range_fn = read_range,
            .write_fn = write,
            .begin_write_fn = begin_write,
            .delete_fn = delete,
        };
    }

    fn root_slice(self: *const FileClient) []const u8 {
        return self.root[0..self.root_bytes];
    }

    fn file_path(
        self: *FileClient,
        workspace: *[std.Io.Dir.max_path_bytes]u8,
        level: u8,
        identity: ltx.FileIdentity,
    ) Error![]const u8 {
        return ltx.format_file_path(
            self.root_slice(),
            level,
            identity,
            workspace,
        ) catch return error.PathTooLong;
    }

    fn list(
        context: *anyopaque,
        level: u8,
        seek: ltx.TXID,
        destination: []ltx.FileInfo,
    ) Error![]const ltx.FileInfo {
        const self: *FileClient = @ptrCast(@alignCast(context));
        const level_dir = try level_directory_path(self, &self.path_a, level);
        var dir = self.dir.openDir(self.io, level_dir, .{ .iterate = true }) catch |err| {
            return switch (err) {
                error.FileNotFound => destination[0..0],
                else => error.StorageFailure,
            };
        };
        defer dir.close(self.io);
        var count: usize = 0;
        var iterator = dir.iterate();
        while (true) {
            const entry = iterator.next(self.io) catch return error.StorageFailure;
            const current = entry orelse break;
            if (current.kind != .file) continue;
            const identity = ltx.parse_file_name(current.name) catch continue;
            if (identity.min_txid.value < seek.value) continue;
            if (count == destination.len) return error.ListingCapacityExceeded;
            const stat = dir.statFile(self.io, current.name, .{}) catch
                return error.StorageFailure;
            destination[count] = .{
                .level = level,
                .min_txid = identity.min_txid,
                .max_txid = identity.max_txid,
                .size_bytes = stat.size,
            };
            count += 1;
        }
        const listed = destination[0..count];
        std.sort.pdq(ltx.FileInfo, listed, {}, file_info_before);
        return listed;
    }

    fn read_range(
        context: *anyopaque,
        info: ltx.FileInfo,
        expected_generation: ?ReadGeneration,
        offset_bytes: u64,
        destination: []u8,
    ) Error!ReadGeneration {
        const self: *FileClient = @ptrCast(@alignCast(context));
        const path = try self.file_path(&self.path_a, info.level, .{
            .min_txid = info.min_txid,
            .max_txid = info.max_txid,
        });
        var file = self.dir.openFile(self.io, path, .{}) catch |err| {
            return switch (err) {
                error.FileNotFound => error.ObjectNotFound,
                else => error.StorageFailure,
            };
        };
        defer file.close(self.io);
        const before_stat = file.stat(self.io) catch return error.StorageFailure;
        if (before_stat.size != info.size_bytes) return error.ObjectChanged;
        const before_generation = try file_generation(before_stat);
        if (expected_generation) |expected| {
            if (!expected.eql(before_generation)) return error.ObjectChanged;
        }
        const read = file.readPositionalAll(self.io, destination, offset_bytes) catch
            return error.StorageFailure;
        if (read != destination.len) return error.ObjectChanged;
        const after_stat = file.stat(self.io) catch return error.StorageFailure;
        if (after_stat.size != info.size_bytes) return error.ObjectChanged;
        const after_generation = try file_generation(after_stat);
        if (!before_generation.eql(after_generation)) return error.ObjectChanged;
        return after_generation;
    }

    fn write(
        context: *anyopaque,
        level: u8,
        identity: ltx.FileIdentity,
        created_at_ms: i64,
        bytes: []const u8,
    ) Error!void {
        _ = created_at_ms;
        const self: *FileClient = @ptrCast(@alignCast(context));
        if (self.write_session_active) return error.InvalidState;
        const final_path = try self.file_path(&self.path_a, level, identity);
        const level_dir = try level_directory_path(self, &self.path_b, level);
        try ensure_level_directory(self, level, level_dir);
        const staged = try create_unique_temporary(self, final_path, &self.path_b);
        try write_temporary_then_rename(self, staged, final_path, bytes);
    }

    fn begin_write(
        context: *anyopaque,
        level: u8,
        identity: ltx.FileIdentity,
        created_at_ms: i64,
    ) Error!WriteSession {
        _ = created_at_ms;
        const self: *FileClient = @ptrCast(@alignCast(context));
        if (self.write_session_active) return error.InvalidState;
        const final_path = try self.file_path(&self.write_final_path, level, identity);
        self.write_final_path_bytes = final_path.len;
        const level_dir = try level_directory_path(self, &self.path_a, level);
        try ensure_level_directory(self, level, level_dir);
        const staged = try create_unique_temporary(
            self,
            final_path,
            &self.write_temporary_path,
        );
        self.write_temporary_path_bytes = staged.path.len;
        self.write_session_file = staged.file;
        self.write_offset_bytes = 0;
        self.write_session_active = true;
        return WriteSession.init(.{
            .context = self,
            .write_fn = write_session_chunk,
            .finish_fn = finish_write_session,
            .abort_fn = abort_write_session,
        });
    }

    fn write_session_chunk(context: *anyopaque, bytes: []const u8) Error!void {
        const self: *FileClient = @ptrCast(@alignCast(context));
        const file = self.write_session_file orelse return error.InvalidState;
        if (!self.write_session_active) return error.InvalidState;
        const count_bytes = std.math.cast(u64, bytes.len) orelse
            return error.ObjectTooLarge;
        const end_bytes = std.math.add(u64, self.write_offset_bytes, count_bytes) catch
            return error.ObjectTooLarge;
        file.writePositionalAll(self.io, bytes, self.write_offset_bytes) catch
            return error.StorageFailure;
        self.write_offset_bytes = end_bytes;
    }

    fn finish_write_session(context: *anyopaque) Error!void {
        const self: *FileClient = @ptrCast(@alignCast(context));
        const file = self.write_session_file orelse return error.InvalidState;
        if (!self.write_session_active) return error.InvalidState;
        file.sync(self.io) catch return error.StorageFailure;
        file.close(self.io);
        self.write_session_file = null;
        self.dir.rename(
            self.write_temporary_path[0..self.write_temporary_path_bytes],
            self.dir,
            self.write_final_path[0..self.write_final_path_bytes],
            self.io,
        ) catch return error.StorageFailure;
        sync_parent_directory(
            self,
            self.write_final_path[0..self.write_final_path_bytes],
        ) catch {
            self.end_write_session();
            return error.PublicationIndeterminate;
        };
        self.end_write_session();
    }

    fn abort_write_session(context: *anyopaque) void {
        const self: *FileClient = @ptrCast(@alignCast(context));
        if (self.write_session_file) |file| {
            file.close(self.io);
            self.write_session_file = null;
        }
        if (self.write_session_active) {
            self.dir.deleteFile(
                self.io,
                self.write_temporary_path[0..self.write_temporary_path_bytes],
            ) catch {};
        }
        self.end_write_session();
    }

    fn end_write_session(self: *FileClient) void {
        self.write_session_active = false;
        self.write_offset_bytes = 0;
        self.write_final_path_bytes = 0;
        self.write_temporary_path_bytes = 0;
    }

    fn delete(
        context: *anyopaque,
        files: []const ltx.FileInfo,
    ) Error!void {
        const self: *FileClient = @ptrCast(@alignCast(context));
        if (self.write_session_active) return error.InvalidState;
        for (files) |info| {
            const path = try self.file_path(
                &self.path_a,
                info.level,
                .{ .min_txid = info.min_txid, .max_txid = info.max_txid },
            );
            self.dir.deleteFile(self.io, path) catch |err| switch (err) {
                error.FileNotFound => {},
                else => return error.StorageFailure,
            };
        }
    }
};

fn file_generation(stat: std.Io.File.Stat) Error!ReadGeneration {
    var bytes: [49]u8 = undefined;
    const inode = std.math.cast(u64, stat.inode) orelse
        return error.StorageFailure;
    const nlink = std.math.cast(u64, stat.nlink) orelse
        return error.StorageFailure;
    std.mem.writeInt(u64, bytes[0..8], inode, .big);
    std.mem.writeInt(u64, bytes[8..16], nlink, .big);
    std.mem.writeInt(u64, bytes[16..24], stat.size, .big);
    std.mem.writeInt(i96, bytes[24..36], stat.mtime.nanoseconds, .big);
    std.mem.writeInt(i96, bytes[36..48], stat.ctime.nanoseconds, .big);
    bytes[48] = @intCast(@intFromEnum(stat.kind));
    return ReadGeneration.init(&bytes);
}

fn level_directory_path(
    self: *FileClient,
    workspace: *[std.Io.Dir.max_path_bytes]u8,
    level: u8,
) Error![]const u8 {
    if (level > ltx.max_level) return error.InvalidLevel;
    var offset = self.root_bytes;
    if (offset > workspace.len) return error.PathTooLong;
    @memcpy(workspace[0..offset], self.root_slice());
    try append_separator(workspace, &offset);
    try append_path(workspace, &offset, ltx.ltx_directory_name);
    try append_separator(workspace, &offset);
    var level_name: [1]u8 = undefined;
    try append_path(
        workspace,
        &offset,
        ltx.format_filesystem_level_name(level, &level_name) catch
            return error.InvalidLevel,
    );
    return workspace[0..offset];
}

fn append_separator(destination: []u8, offset: *usize) Error!void {
    if (offset.* == 0) return;
    try append_path(destination, offset, "/");
}

const TemporaryFile = struct {
    file: std.Io.File,
    path: []const u8,
};

fn create_unique_temporary(
    self: *FileClient,
    final_path: []const u8,
    workspace: *[std.Io.Dir.max_path_bytes]u8,
) Error!TemporaryFile {
    const required = std.math.add(usize, final_path.len, temporary_suffix_bytes) catch
        return error.PathTooLong;
    if (required > workspace.len) {
        return error.PathTooLong;
    }
    @memcpy(workspace[0..final_path.len], final_path);
    var candidate: u16 = 0;
    while (candidate < temporary_candidate_count) : (candidate += 1) {
        const suffix = std.fmt.bufPrint(
            workspace[final_path.len..required],
            ".tmp-{x:0>4}",
            .{candidate},
        ) catch return error.PathTooLong;
        const path = workspace[0 .. final_path.len + suffix.len];
        const file = self.dir.createFile(self.io, path, .{
            .truncate = false,
            .exclusive = true,
        }) catch |err| switch (err) {
            error.PathAlreadyExists => continue,
            else => return error.StorageFailure,
        };
        return .{ .file = file, .path = path };
    }
    return error.StagingCapacityExceeded;
}

const temporary_candidate_count: u16 = 256;
const temporary_suffix_bytes = ".tmp-0000".len;

fn write_temporary_then_rename(
    self: *FileClient,
    staged: TemporaryFile,
    final_path: []const u8,
    bytes: []const u8,
) Error!void {
    const temporary = staged.path;
    const file = staged.file;
    var file_open = true;
    defer if (file_open) file.close(self.io);
    var temporary_exists = true;
    defer if (temporary_exists) self.dir.deleteFile(self.io, temporary) catch {};
    file.writePositionalAll(self.io, bytes, 0) catch return error.StorageFailure;
    file.sync(self.io) catch return error.StorageFailure;
    file.close(self.io);
    file_open = false;
    self.dir.rename(temporary, self.dir, final_path, self.io) catch
        return error.StorageFailure;
    temporary_exists = false;
    sync_parent_directory(self, final_path) catch
        return error.PublicationIndeterminate;
}

fn sync_parent_directory(self: *FileClient, final_path: []const u8) Error!void {
    const parent_path = std.Io.Dir.path.dirname(final_path) orelse ".";
    return sync_directory(self, parent_path);
}

fn ensure_level_directory(
    self: *FileClient,
    level: u8,
    level_path: []const u8,
) Error!void {
    const status = self.dir.createDirPathStatus(
        self.io,
        level_path,
        .default_dir,
    ) catch return error.StorageFailure;
    const level_index: usize = @intCast(level);
    if (status == .existed and self.level_directories_synced[level_index]) return;
    try sync_directory_chain(self, level_path);
    self.level_directories_synced[level_index] = true;
}

fn sync_directory_chain(self: *FileClient, deepest_path: []const u8) Error!void {
    var current: ?[]const u8 = deepest_path;
    var step_count: usize = 0;
    while (step_count <= deepest_path.len) : (step_count += 1) {
        const path = current orelse {
            try sync_directory(self, ".");
            return;
        };
        try sync_directory(self, path);
        current = std.Io.Dir.path.dirname(path);
    }
    return error.PathTooLong;
}

fn sync_directory(self: *FileClient, path: []const u8) Error!void {
    var file = self.dir.openFile(self.io, path, .{
        .mode = .read_only,
        .allow_directory = true,
        .follow_symlinks = false,
        .resolve_beneath = true,
    }) catch return error.StorageFailure;
    defer file.close(self.io);
    file.sync(self.io) catch return error.StorageFailure;
}

fn append_path(destination: []u8, offset: *usize, bytes: []const u8) Error!void {
    const end = std.math.add(usize, offset.*, bytes.len) catch
        return error.PathTooLong;
    if (end > destination.len) return error.PathTooLong;
    @memcpy(destination[offset.*..end], bytes);
    offset.* = end;
}

fn file_info_before(_: void, left: ltx.FileInfo, right: ltx.FileInfo) bool {
    if (left.min_txid.value != right.min_txid.value) {
        return left.min_txid.value < right.min_txid.value;
    }
    return left.max_txid.value < right.max_txid.value;
}

/// Backend-agnostic conformance suite. Run it against empty storage: it
/// writes at levels 0 and 1, asserts the listing, seek, ranged read, idempotent
/// overwrite, generation-bound refill, and delete contracts, and deletes what
/// it wrote. Returns `ConformanceFailure` on the first violated contract.
pub fn run_conformance(client: Client) Error!void {
    const first = ltx.FileIdentity{
        .min_txid = ltx.TXID.init(1),
        .max_txid = ltx.TXID.init(1),
    };
    const second = ltx.FileIdentity{
        .min_txid = ltx.TXID.init(2),
        .max_txid = ltx.TXID.init(2),
    };
    const third = ltx.FileIdentity{
        .min_txid = ltx.TXID.init(3),
        .max_txid = ltx.TXID.init(3),
    };
    const span = ltx.FileIdentity{
        .min_txid = ltx.TXID.init(1),
        .max_txid = ltx.TXID.init(3),
    };

    var infos: [8]ltx.FileInfo = undefined;
    const empty = try client.list(0, ltx.TXID.init(0), &infos);
    if (empty.len != 0) return error.ConformanceFailure;

    var one: [8]u8 = undefined;
    var two: [8]u8 = undefined;
    var three: [8]u8 = undefined;
    @memset(&one, 0x01);
    @memset(&two, 0x02);
    @memset(&three, 0x03);
    try client.write(0, first, 1000, &one);
    try client.write(0, second, 2000, &two);
    try client.write(0, third, 3000, &three);
    try client.write(1, span, 4000, &one);

    const listed = try client.list(0, ltx.TXID.init(0), &infos);
    if (listed.len != 3) return error.ConformanceFailure;
    if (listed[0].min_txid.value != 1 or listed[2].max_txid.value != 3) {
        return error.ConformanceFailure;
    }
    for (listed) |info| {
        if (info.size_bytes != one.len) return error.ConformanceFailure;
    }
    const sought = try client.list(0, ltx.TXID.init(2), &infos);
    if (sought.len != 2 or sought[0].min_txid.value != 2) {
        return error.ConformanceFailure;
    }
    const compacted = try client.list(1, ltx.TXID.init(0), &infos);
    if (compacted.len != 1 or compacted[0].max_txid.value != 3) {
        return error.ConformanceFailure;
    }

    const second_info = ltx.FileInfo{
        .level = 0,
        .min_txid = second.min_txid,
        .max_txid = second.max_txid,
        .size_bytes = two.len,
    };
    var storage: [8]u8 = undefined;
    if (!std.mem.eql(u8, try client.read_all(second_info, &storage), &two)) {
        return error.ConformanceFailure;
    }
    var first_range: [2]u8 = undefined;
    try client.read_range(second_info, 0, &first_range);
    if (!std.mem.eql(u8, &first_range, two[0..2])) return error.ConformanceFailure;
    var middle_range: [3]u8 = undefined;
    try client.read_range(second_info, 2, &middle_range);
    if (!std.mem.eql(u8, &middle_range, two[2..5])) return error.ConformanceFailure;
    var final_range: [1]u8 = undefined;
    try client.read_range(second_info, 7, &final_range);
    if (!std.mem.eql(u8, &final_range, two[7..8])) return error.ConformanceFailure;
    try client.read_range(second_info, second_info.size_bytes, storage[0..0]);

    var undersized: [7]u8 = undefined;
    try expect_error(error.ObjectTooLarge, client.read_all(second_info, &undersized));
    try expect_error(
        error.InvalidReadRange,
        client.read_range(second_info, second_info.size_bytes, final_range[0..1]),
    );
    try expect_error(
        error.InvalidReadRange,
        client.read_range(second_info, std.math.maxInt(u64), storage[0..0]),
    );
    var stale_info = second_info;
    stale_info.size_bytes -= 1;
    try expect_error(
        error.ObjectChanged,
        client.read_range(stale_info, 0, storage[0..1]),
    );

    var read_workspace: [3]u8 = undefined;
    var source = try ObjectReader.init(client, second_info, &read_workspace);
    const reader = source.reader();
    var original_prefix: [3]u8 = undefined;
    if (reader.read(&original_prefix)) |count_bytes| {
        if (count_bytes != original_prefix.len or
            !std.mem.eql(u8, &original_prefix, two[0..original_prefix.len]))
        {
            return error.ConformanceFailure;
        }
    } else |_| {
        return error.ConformanceFailure;
    }

    // Overwrite is idempotent, but an existing reader remains bound to the
    // generation that supplied its first range.
    @memset(&two, 0x22);
    try client.write(0, second, 2500, &two);
    if (reader.read(storage[0..3])) |_| {
        return error.ConformanceFailure;
    } else |err| {
        if (err != error.InputFailure) return error.ConformanceFailure;
    }
    const failure = source.failure() orelse return error.ConformanceFailure;
    if (failure != error.ObjectChanged) return error.ConformanceFailure;
    if ((try client.list(0, ltx.TXID.init(0), &infos)).len != 3) {
        return error.ConformanceFailure;
    }
    if (!std.mem.eql(u8, try client.read_all(second_info, &storage), &two)) {
        return error.ConformanceFailure;
    }

    // Capacity is an explicit error, not silent truncation.
    var small: [2]ltx.FileInfo = undefined;
    try expect_error(
        error.ListingCapacityExceeded,
        client.list(0, ltx.TXID.init(0), &small),
    );

    try client.delete(&.{
        .{ .level = 0, .min_txid = first.min_txid, .max_txid = first.max_txid, .size_bytes = one.len },
        .{ .level = 0, .min_txid = third.min_txid, .max_txid = third.max_txid, .size_bytes = three.len },
    });
    const remaining = try client.list(0, ltx.TXID.init(0), &infos);
    if (remaining.len != 1 or remaining[0].min_txid.value != 2) {
        return error.ConformanceFailure;
    }
    try expect_error(
        error.ObjectNotFound,
        client.read_range(.{
            .level = 0,
            .min_txid = first.min_txid,
            .max_txid = first.max_txid,
            .size_bytes = one.len,
        }, 0, storage[0..1]),
    );
    // Deleting a missing object is idempotent.
    try client.delete(&.{
        .{ .level = 0, .min_txid = first.min_txid, .max_txid = first.max_txid, .size_bytes = one.len },
    });

    try expect_error(error.InvalidLevel, client.list(10, ltx.TXID.init(0), &infos));
    try expect_error(
        error.InvalidIdentity,
        client.write(0, .{ .min_txid = ltx.TXID.init(4), .max_txid = ltx.TXID.init(2) }, 0, &one),
    );

    try client.delete(&.{
        .{ .level = 0, .min_txid = second.min_txid, .max_txid = second.max_txid, .size_bytes = two.len },
        .{ .level = 1, .min_txid = span.min_txid, .max_txid = span.max_txid, .size_bytes = one.len },
    });
    if ((try client.list(0, ltx.TXID.init(0), &infos)).len != 0) {
        return error.ConformanceFailure;
    }
}

fn expect_error(expected: Error, result: anytype) Error!void {
    if (result) |_| {
        return error.ConformanceFailure;
    } else |err| {
        if (err != expected) return err;
    }
}
