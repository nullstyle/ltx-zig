//! Storage-neutral LTX object access.
//!
//! The `Client` contract mirrors the storage half of the pinned Celld crate's
//! `ReplicaClient` trait: listings ascending by TXID range, whole-object
//! reads, idempotent writes, and idempotent deletes — all over caller-owned
//! buffers, with no allocation inside this module. Objects are opaque byte
//! blobs at this layer; only their level and TXID-range identity are
//! meaningful here.
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
    ObjectNotFound,
    ObjectExists,
    InvalidState,
    ObjectTooLarge,
    StorageFailure,
    ListingCapacityExceeded,
    PathTooLong,
    ConformanceFailure,
};

/// One LTX object store. Callbacks must be synchronous and non-reentrant.
/// All variable-size results are written into caller-owned storage.
pub const Client = struct {
    context: *anyopaque,
    /// Lists the level's objects ascending by `(min_txid, max_txid)`,
    /// including only objects whose minimum TXID is at least `seek`.
    /// Returns the filled prefix of `destination`.
    list_fn: *const fn (
        context: *anyopaque,
        level: u8,
        seek: ltx.TXID,
        destination: []ltx.FileInfo,
    ) Error![]const ltx.FileInfo,
    /// Reads one whole object into `destination`, returning the byte slice
    /// occupied. `destination` must be at least the object's size.
    open_fn: *const fn (
        context: *anyopaque,
        level: u8,
        identity: ltx.FileIdentity,
        destination: []u8,
    ) Error![]const u8,
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

    pub fn open(
        self: Client,
        level: u8,
        identity: ltx.FileIdentity,
        destination: []u8,
    ) Error![]const u8 {
        if (level > ltx.max_level) return error.InvalidLevel;
        if (identity.min_txid.value > identity.max_txid.value) {
            return error.InvalidIdentity;
        }
        return self.open_fn(self.context, level, identity, destination);
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

    pub fn delete(self: Client, files: []const ltx.FileInfo) Error!void {
        return self.delete_fn(self.context, files);
    }
};

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
            .open_fn = open,
            .write_fn = write,
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
            destination[count] = .{
                .level = level,
                .min_txid = identity.min_txid,
                .max_txid = identity.max_txid,
            };
            count += 1;
        }
        const listed = destination[0..count];
        std.sort.pdq(ltx.FileInfo, listed, {}, file_info_before);
        return listed;
    }

    fn open(
        context: *anyopaque,
        level: u8,
        identity: ltx.FileIdentity,
        destination: []u8,
    ) Error![]const u8 {
        const self: *FileClient = @ptrCast(@alignCast(context));
        const path = try self.file_path(&self.path_a, level, identity);
        const stat = self.dir.statFile(self.io, path, .{}) catch |err| {
            return switch (err) {
                error.FileNotFound => error.ObjectNotFound,
                else => error.StorageFailure,
            };
        };
        const size = std.math.cast(usize, stat.size) orelse return error.ObjectTooLarge;
        if (size > destination.len) return error.ObjectTooLarge;
        var file = self.dir.openFile(self.io, path, .{}) catch |err| {
            return switch (err) {
                error.FileNotFound => error.ObjectNotFound,
                else => error.StorageFailure,
            };
        };
        defer file.close(self.io);
        const read = file.readPositionalAll(self.io, destination[0..size], 0) catch
            return error.StorageFailure;
        if (read != size) return error.StorageFailure;
        return destination[0..size];
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
        const final_path = try self.file_path(&self.path_a, level, identity);
        const level_dir = try level_directory_path(self, &self.path_b, level);
        self.dir.createDirPath(self.io, level_dir) catch return error.StorageFailure;
        const temporary = try temporary_path(self, final_path, &self.path_b);
        write_temporary_then_rename(self, temporary, final_path, bytes) catch |err| {
            self.dir.deleteFile(self.io, temporary) catch {};
            return err;
        };
    }

    fn delete(
        context: *anyopaque,
        files: []const ltx.FileInfo,
    ) Error!void {
        const self: *FileClient = @ptrCast(@alignCast(context));
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

fn temporary_path(
    self: *FileClient,
    final_path: []const u8,
    workspace: *[std.Io.Dir.max_path_bytes]u8,
) Error![]const u8 {
    _ = self;
    if (final_path.len + temporary_suffix.len > workspace.len) {
        return error.PathTooLong;
    }
    @memcpy(workspace[0..final_path.len], final_path);
    @memcpy(workspace[final_path.len..][0..temporary_suffix.len], temporary_suffix);
    return workspace[0 .. final_path.len + temporary_suffix.len];
}

const temporary_suffix = ".tmp";

fn write_temporary_then_rename(
    self: *FileClient,
    temporary: []const u8,
    final_path: []const u8,
    bytes: []const u8,
) Error!void {
    var file = self.dir.createFile(self.io, temporary, .{ .truncate = true }) catch
        return error.StorageFailure;
    var succeeded = false;
    defer if (!succeeded) self.dir.deleteFile(self.io, temporary) catch {};
    file.writePositionalAll(self.io, bytes, 0) catch return error.StorageFailure;
    file.sync(self.io) catch return error.StorageFailure;
    file.close(self.io);
    self.dir.rename(temporary, self.dir, final_path, self.io) catch
        return error.StorageFailure;
    succeeded = true;
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
/// writes at levels 0 and 1, asserts the listing, seek, read, idempotent
/// overwrite, and delete contracts, and deletes what it wrote. Returns
/// `ConformanceFailure` on the first violated contract.
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
    const sought = try client.list(0, ltx.TXID.init(2), &infos);
    if (sought.len != 2 or sought[0].min_txid.value != 2) {
        return error.ConformanceFailure;
    }
    const compacted = try client.list(1, ltx.TXID.init(0), &infos);
    if (compacted.len != 1 or compacted[0].max_txid.value != 3) {
        return error.ConformanceFailure;
    }

    var storage: [8]u8 = undefined;
    const opened = try client.open(0, second, &storage);
    if (!std.mem.eql(u8, opened, &two)) return error.ConformanceFailure;

    // Overwrite is idempotent: same identity, new bytes, unchanged listing.
    @memset(&two, 0x22);
    try client.write(0, second, 2500, &two);
    if ((try client.list(0, ltx.TXID.init(0), &infos)).len != 3) {
        return error.ConformanceFailure;
    }
    if (!std.mem.eql(u8, try client.open(0, second, &storage), &two)) {
        return error.ConformanceFailure;
    }

    // Capacity is an explicit error, not silent truncation.
    var small: [2]ltx.FileInfo = undefined;
    try expect_error(
        error.ListingCapacityExceeded,
        client.list(0, ltx.TXID.init(0), &small),
    );

    try client.delete(&.{
        .{ .level = 0, .min_txid = first.min_txid, .max_txid = first.max_txid },
        .{ .level = 0, .min_txid = third.min_txid, .max_txid = third.max_txid },
    });
    const remaining = try client.list(0, ltx.TXID.init(0), &infos);
    if (remaining.len != 1 or remaining[0].min_txid.value != 2) {
        return error.ConformanceFailure;
    }
    try expect_error(error.ObjectNotFound, client.open(0, first, &storage));
    // Deleting a missing object is idempotent.
    try client.delete(&.{
        .{ .level = 0, .min_txid = first.min_txid, .max_txid = first.max_txid },
    });

    try expect_error(error.InvalidLevel, client.list(10, ltx.TXID.init(0), &infos));
    try expect_error(
        error.InvalidIdentity,
        client.write(0, .{ .min_txid = ltx.TXID.init(4), .max_txid = ltx.TXID.init(2) }, 0, &one),
    );

    try client.delete(&.{
        .{ .level = 0, .min_txid = second.min_txid, .max_txid = second.max_txid },
        .{ .level = 1, .min_txid = span.min_txid, .max_txid = span.max_txid },
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
