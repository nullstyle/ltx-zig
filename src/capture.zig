//! SQLite-to-LTX capture.
//!
//! This module is the producer half of the replication library: it holds one
//! read-write SQLite connection in WAL mode, reads committed pages through
//! `ltx_wal`, and publishes verified L0 transitions through an `ltx_object`
//! client. It follows the pinned Celld crate's `db.rs` capture path at the
//! granularity this milestone covers:
//!
//! - the first capture is a full snapshot;
//! - a WAL whose header salts still match the previously captured segment
//!   and whose committed region extends the previously captured offset
//!   produces an incremental;
//! - anything else (a checkpoint-restarted or rewritten WAL) falls back to a
//!   fresh full snapshot, which is always safe because page data missing
//!   from the WAL is read from the database file.
//!
//! Continuing WAL segments resume from the last verified frame boundary.
//! Byte-, age-, and frame-count tiers can trigger passive checkpoints, while
//! the session's single-writer ownership makes Celld's separate writer barrier
//! unnecessary. Crash-replay integration qualifies publication and resume
//! behavior. A WAL larger than the configured workspace is rejected rather
//! than partially read.
//!
//! Captured files use the no-checksum L0 profile exactly like Celld and
//! Litestream: `HEADER_FLAG_NO_CHECKSUM` with zero pre/post-apply checksums.
//! The module declares its SQLite C surface inline; the host build provides
//! the library (see the `capture-integration` gate for the pattern).

const std = @import("std");
const ltx = @import("ltx");
const wal = @import("ltx_wal");
const object = @import("ltx_object");

pub const Error = error{
    SQLiteOpenFailure,
    SQLitePrepareFailure,
    SQLiteStepFailure,
    SQLiteExecFailure,
    SQLiteBusy,
    WALMissing,
    WALTooLarge,
    DatabasePageReadFailure,
    InvalidPageSize,
    CaptureUnchanged,
    CheckpointIncomplete,
    TimestampRegression,
} || ltx.Error || wal.Error || object.Error;

const sqlite_ok: c_int = 0;
const sqlite_row: c_int = 100;
const sqlite_done: c_int = 101;
const sqlite_busy: c_int = 5;
const sqlite_open_readwrite: c_int = 0x0000_0002;
const sqlite_open_create: c_int = 0x0000_0004;
const sqlite_open_uri: c_int = 0x0000_0040;

const wal_suffix = "-wal";

const sqlite = struct {
    extern fn sqlite3_open_v2(
        filename: [*:0]const u8,
        db: *?*anyopaque,
        flags: c_int,
        vfs: ?[*:0]const u8,
    ) c_int;
    extern fn sqlite3_close_v2(db: ?*anyopaque) c_int;
    extern fn sqlite3_exec(
        db: ?*anyopaque,
        sql: [*:0]const u8,
        callback: ?*const anyopaque,
        argument: ?*anyopaque,
        errmsg: ?*?[*:0]u8,
    ) c_int;
    extern fn sqlite3_prepare_v2(
        db: ?*anyopaque,
        sql: [*:0]const u8,
        byte_count: c_int,
        statement: *?*anyopaque,
        tail: ?*?[*:0]const u8,
    ) c_int;
    extern fn sqlite3_step(statement: ?*anyopaque) c_int;
    extern fn sqlite3_finalize(statement: ?*anyopaque) c_int;
    extern fn sqlite3_column_int64(statement: ?*anyopaque, column: c_int) i64;
    extern fn sqlite3_busy_timeout(db: ?*anyopaque, milliseconds: c_int) c_int;
    extern fn sqlite3_extended_result_codes(db: ?*anyopaque, onoff: c_int) c_int;
    extern fn sqlite3_errcode(db: ?*anyopaque) c_int;
};

/// Caller-owned variable storage for capture. `wal_storage` bounds the
/// largest accepted WAL; the four map workspaces follow the
/// `wal_page_map_workspace_bytes` formula for `wal_limits`; the remaining
/// members follow the encoder formula for `codec_limits`. `output_storage`
/// bounds the whole-object fallback and may be empty only when the selected
/// client reports write-session support. All live ranges must be pairwise
/// disjoint. Private staging reachable through `client` is opaque here, so
/// the caller must also keep adapter-owned staging disjoint from these ranges.
pub const Workspaces = struct {
    wal_storage: []u8,
    map_slots: []wal.PageSlot,
    map_pending: []u32,
    map_seen: []u8,
    map_entries: []wal.PageMapEntry,
    output_storage: []u8,
    page_workspace: []u8,
    compressed_workspace: []u8,
    compression_workspace: *ltx.LZ4CompressionWorkspace,
    index_workspace: []ltx.PageIndexEntry,
};

/// One capture session over a SQLite database file. A session is stateful
/// and single-owner: keep it at a stable address, use one session per
/// database, and close it with `finish`.
pub const Session = struct {
    db: ?*anyopaque = null,
    io: std.Io,
    dir: std.Io.Dir,
    /// Absolute NUL-terminated path for the SQLite C API, which resolves
    /// relative names against the process working directory rather than a
    /// directory handle.
    sqlite_path: [2 * std.Io.Dir.max_path_bytes]u8 = undefined,
    sqlite_path_bytes: usize = 0,
    database_path: [std.Io.Dir.max_path_bytes]u8 = undefined,
    database_path_bytes: usize = 0,
    wal_path: [std.Io.Dir.max_path_bytes]u8 = undefined,
    wal_path_bytes: usize = 0,
    codec_limits: ltx.Limits,
    wal_limits: wal.Limits,
    client: object.Client,
    page_size: u32 = 0,
    /// The last published replication position.
    position: ltx.Position = .{
        .txid = ltx.TXID.init(0),
        .post_apply_checksum = ltx.Checksum.init(0),
    },
    segment_salt: wal.SaltPair = .{ .salt_1 = 0, .salt_2 = 0 },
    segment_end_offset_bytes: u64 = 0,
    segment_commit_pages: u32 = 0,
    /// Set after a checkpoint this session initiated: the next committed
    /// WAL frames belong to a fresh segment that continues the captured
    /// position, so they are captured as an incremental rather than
    /// triggering a snapshot fallback.
    segment_restarted: bool = false,
    last_wal_bytes: u64 = 0,
    last_wal_frame_count: u64 = 0,
    /// When nonzero, a successful sync whose WAL reached this size runs a
    /// passive checkpoint afterwards, bounding WAL growth.
    checkpoint_threshold_bytes: u64 = 0,
    /// When nonzero, a successful sync at least this many milliseconds
    /// after the last checkpoint runs one, bounding WAL age for
    /// sparse-but-large writers.
    checkpoint_interval_ms: u64 = 0,
    /// When nonzero, a successful sync whose WAL holds at least this many
    /// frames runs a checkpoint. Together with the byte threshold and the
    /// interval this is the page-count tier; the frame count derives from
    /// the WAL size and page size, so it stays exact without tracking
    /// frames. The writer-barrier tier from the ported daemon does not
    /// apply: this session is the single writer of its database.
    checkpoint_max_frames: u32 = 0,
    last_checkpoint_ms: i64 = std.math.minInt(i64),
    checkpoint_clock_started: bool = false,
    /// A requested checkpoint did not complete and should be retried. Manual
    /// checkpoint callers observe the error; automatic policy leaves a
    /// successfully published capture successful and exposes the retry here.
    checkpoint_pending: bool = false,
    /// Last timestamp accepted by `sync`, including an unchanged capture.
    last_sync_ms: ?i64 = null,

    /// Opens `database_name` (created when absent) under `dir` in WAL mode
    /// with automatic checkpointing disabled, creates the Litestream control
    /// tables, and reads the page size.
    pub fn init(
        dir: std.Io.Dir,
        io: std.Io,
        database_name: []const u8,
        codec_limits: ltx.Limits,
        wal_limits: wal.Limits,
        client: object.Client,
    ) Error!Session {
        if (database_name.len + wal_suffix.len > std.Io.Dir.max_path_bytes) {
            return error.SQLiteOpenFailure;
        }
        var self = Session{
            .io = io,
            .dir = dir,
            .codec_limits = codec_limits,
            .wal_limits = wal_limits,
            .client = client,
        };
        @memcpy(self.database_path[0..database_name.len], database_name);
        self.database_path_bytes = database_name.len;
        @memcpy(self.wal_path[0..database_name.len], database_name);
        @memcpy(self.wal_path[database_name.len..][0..wal_suffix.len], wal_suffix);
        self.wal_path_bytes = database_name.len + wal_suffix.len;

        var absolute_root: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const base_length = self.dir.realPath(self.io, &absolute_root) catch
            return error.SQLiteOpenFailure;
        const written = std.fmt.bufPrint(
            &self.sqlite_path,
            "{s}/{s}",
            .{ absolute_root[0..base_length], database_name },
        ) catch return error.SQLiteOpenFailure;
        self.sqlite_path_bytes = written.len;
        self.sqlite_path[self.sqlite_path_bytes] = 0;
        const flags = sqlite_open_readwrite | sqlite_open_create | sqlite_open_uri;
        if (sqlite.sqlite3_open_v2(
            @ptrCast(&self.sqlite_path),
            &self.db,
            flags,
            null,
        ) != sqlite_ok) return error.SQLiteOpenFailure;
        errdefer self.finish();
        _ = sqlite.sqlite3_busy_timeout(self.db, 1000);
        _ = sqlite.sqlite3_extended_result_codes(self.db, 0);
        try self.exec("PRAGMA journal_mode=WAL");
        try self.exec("PRAGMA synchronous=NORMAL");
        try self.exec("PRAGMA wal_autocheckpoint=0");
        try self.exec(
            \\CREATE TABLE IF NOT EXISTS _litestream_seq (
            \\  id INTEGER PRIMARY KEY CHECK (id = 1),
            \\  seq INTEGER NOT NULL
            \\)
        );
        try self.exec("INSERT OR IGNORE INTO _litestream_seq (id, seq) VALUES (1, 0)");
        try self.exec(
            \\CREATE TABLE IF NOT EXISTS _litestream_lock (
            \\  id INTEGER PRIMARY KEY CHECK (id = 1)
            \\)
        );
        self.page_size = @intCast(try self.query_int64("PRAGMA page_size", 0));
        if (!ltx.is_valid_page_size(self.page_size)) return error.InvalidPageSize;
        if (self.page_size > self.wal_limits.max_page_size) return error.InvalidPageSize;
        if (self.page_size > self.codec_limits.max_page_size) {
            return error.InvalidPageSize;
        }
        return self;
    }

    /// Executes one SQL statement. Intended for schema setup and host-side
    /// maintenance; capture itself only uses PRAGMAs and control-table reads.
    pub fn exec(self: *Session, sql: [*:0]const u8) Error!void {
        if (sqlite.sqlite3_exec(self.db, sql, null, null, null) != sqlite_ok) {
            return switch (sqlite.sqlite3_errcode(self.db)) {
                sqlite_busy => error.SQLiteBusy,
                else => error.SQLiteExecFailure,
            };
        }
    }

    /// Continues a replica recovered from the object store: seeds the
    /// position so the next capture publishes at the following TXID instead
    /// of restarting the numbering at one. Only valid before the first
    /// sync; the recovered database's WAL is a new segment, so the next
    /// transition is a full snapshot at the seeded position plus one.
    pub fn seed_position(self: *Session, position: ltx.Position) Error!void {
        if (self.position.txid.value != 0) return error.InvalidState;
        self.position = position;
    }

    /// Runs one capture under the checkpoint-blocking read lock, classifies
    /// the transition, encodes it, publishes it at level zero, and advances
    /// the position. `timestamp_ms` is stored in the emitted header. Returns
    /// the encoded page count; `CaptureUnchanged` means no committed
    /// transaction exists beyond the captured position. Automatic checkpoint
    /// failures never mask a published capture; `checkpoint_pending` exposes
    /// the deferred retry, which a later due sync attempts again.
    pub fn sync(self: *Session, workspaces: *Workspaces, timestamp_ms: i64) Error!u32 {
        try self.validate_workspaces(workspaces);
        try self.validate_timestamp(timestamp_ms);
        try self.exec("BEGIN");
        const captured = self.sync_locked(workspaces, timestamp_ms) catch |err| {
            self.exec("ROLLBACK") catch {};
            if (err == error.CaptureUnchanged) {
                self.record_sync_timestamp(timestamp_ms);
                self.checkpoint_if_due(timestamp_ms);
            }
            return err;
        };
        self.exec("ROLLBACK") catch {};
        self.record_sync_timestamp(timestamp_ms);
        self.checkpoint_if_due(timestamp_ms);
        return captured;
    }

    fn checkpoint_if_due(self: *Session, timestamp_ms: i64) void {
        const over_bytes = self.checkpoint_threshold_bytes != 0 and
            self.last_wal_bytes >= self.checkpoint_threshold_bytes;
        const over_frames = self.checkpoint_max_frames != 0 and
            self.last_wal_frame_count >= self.checkpoint_max_frames;
        const elapsed_ms = elapsed_milliseconds(
            timestamp_ms,
            self.last_checkpoint_ms,
        ) catch unreachable;
        const over_time = self.checkpoint_interval_ms != 0 and
            elapsed_ms >= self.checkpoint_interval_ms;
        if (!self.checkpoint_pending and !over_bytes and !over_frames and !over_time) return;
        self.checkpoint_passive(timestamp_ms) catch {};
    }

    fn validate_workspaces(self: *const Session, workspaces: *const Workspaces) Error!void {
        const page_size = std.math.cast(usize, self.page_size) orelse
            return error.InvalidPageSize;
        if (workspaces.page_workspace.len < page_size) return error.WorkspaceTooSmall;
        const live_output = if (self.client.supports_write_sessions())
            workspaces.output_storage[0..0]
        else
            workspaces.output_storage;
        const ranges = [_][]const u8{
            workspaces.wal_storage,
            std.mem.sliceAsBytes(workspaces.map_slots),
            std.mem.sliceAsBytes(workspaces.map_pending),
            workspaces.map_seen,
            std.mem.sliceAsBytes(workspaces.map_entries),
            live_output,
            workspaces.page_workspace,
            workspaces.compressed_workspace,
            std.mem.asBytes(workspaces.compression_workspace),
            std.mem.sliceAsBytes(workspaces.index_workspace),
        };
        for (ranges, 0..) |left, left_index| {
            var right_index = left_index + 1;
            while (right_index < ranges.len) : (right_index += 1) {
                if (slices_overlap(left, ranges[right_index])) {
                    return error.WorkspaceAliasing;
                }
            }
        }
    }

    fn validate_timestamp(self: *const Session, timestamp_ms: i64) Error!void {
        if (self.last_sync_ms) |previous_ms| {
            _ = try elapsed_milliseconds(timestamp_ms, previous_ms);
        }
        if (self.checkpoint_clock_started) {
            _ = try elapsed_milliseconds(timestamp_ms, self.last_checkpoint_ms);
        }
    }

    fn record_sync_timestamp(self: *Session, timestamp_ms: i64) void {
        self.last_sync_ms = timestamp_ms;
        if (!self.checkpoint_clock_started) {
            self.last_checkpoint_ms = timestamp_ms;
            self.checkpoint_clock_started = true;
        }
    }

    /// Runs a passive checkpoint outside the read lock and writes a control
    /// row so the restarted WAL carries a committed frame. Frames committed
    /// after this call continue the captured position as an incremental; a
    /// checkpoint performed by anyone else still falls back to a snapshot.
    /// `CheckpointIncomplete` means a reader prevented a complete pass and
    /// leaves `checkpoint_pending` set for a later retry.
    pub fn checkpoint_passive(self: *Session, now_ms: i64) Error!void {
        try self.validate_timestamp(now_ms);
        self.checkpoint_pending = true;
        const progress = try self.passive_checkpoint_progress();
        if (!progress.complete()) return error.CheckpointIncomplete;
        try self.exec("UPDATE _litestream_seq SET seq = seq + 1 WHERE id = 1");
        self.segment_restarted = true;
        self.segment_end_offset_bytes = 0;
        self.last_checkpoint_ms = now_ms;
        self.checkpoint_clock_started = true;
        self.checkpoint_pending = false;
    }

    fn passive_checkpoint_progress(self: *Session) Error!CheckpointProgress {
        var statement: ?*anyopaque = null;
        if (sqlite.sqlite3_prepare_v2(
            self.db,
            "PRAGMA wal_checkpoint(PASSIVE)",
            -1,
            &statement,
            null,
        ) != sqlite_ok) return error.SQLitePrepareFailure;
        defer _ = sqlite.sqlite3_finalize(statement);
        const first_step = sqlite.sqlite3_step(statement);
        if (first_step != sqlite_row) return sqlite_step_error(first_step);
        const progress = CheckpointProgress{
            .busy = sqlite.sqlite3_column_int64(statement, 0),
            .log_frames = sqlite.sqlite3_column_int64(statement, 1),
            .checkpointed_frames = sqlite.sqlite3_column_int64(statement, 2),
        };
        const final_step = sqlite.sqlite3_step(statement);
        if (final_step != sqlite_done) return sqlite_step_error(final_step);
        return progress;
    }

    fn sync_locked(
        self: *Session,
        workspaces: *Workspaces,
        timestamp_ms: i64,
    ) Error!u32 {
        _ = try self.query_int64("SELECT seq FROM _litestream_seq WHERE id = 1", 0);
        const wal_bytes = try self.read_wal(workspaces.wal_storage);
        if (wal_bytes.len == 0) {
            return self.encode_database_snapshot(workspaces, timestamp_ms);
        }
        if (wal_bytes.len < wal.header_size_bytes) return error.TruncatedHeader;
        const header = try wal.decode_header(wal_bytes[0..wal.header_size_bytes]);
        const first_capture = self.position.txid.value == 0;
        const salts_match = header.salt_1 == self.segment_salt.salt_1 and
            header.salt_2 == self.segment_salt.salt_2;
        // A continuing segment with a previous frame resumes mid-WAL: the
        // reader seeds the cumulative checksum from the last captured frame
        // and scans only new frames. Segments are append-only, so bytes
        // before the resume point were verified by the earlier full scan.
        const one_frame = wal.frame_header_size_bytes + header.page_size;
        const wal_size_bytes = std.math.cast(u64, wal_bytes.len) orelse
            return error.WALTooLarge;
        const reaches_previous_end = wal_size_bytes >= self.segment_end_offset_bytes;
        const resumable = !first_capture and !self.segment_restarted and salts_match and
            reaches_previous_end and
            self.segment_end_offset_bytes >= wal.header_size_bytes + one_frame;
        var reader = if (resumable)
            try wal.Reader.init_with_offset(
                self.wal_limits,
                wal_bytes,
                self.segment_end_offset_bytes,
                self.segment_salt,
            )
        else
            try wal.Reader.init(self.wal_limits, wal_bytes);
        const map = try reader.page_map(.{
            .slots = workspaces.map_slots,
            .pending_pages = workspaces.map_pending,
            .pending_seen = workspaces.map_seen,
            .entries = workspaces.map_entries,
        });

        const segment_continues = self.segment_restarted or
            (salts_match and reaches_previous_end);
        if (map.end_offset_bytes == 0) {
            if (resumable) return error.CaptureUnchanged;
            return self.encode_database_snapshot(workspaces, timestamp_ms);
        }
        if (!first_capture and segment_continues and
            map.end_offset_bytes <= self.segment_end_offset_bytes)
        {
            return error.CaptureUnchanged;
        }
        const incremental = !first_capture and segment_continues;
        return self.encode_and_publish(
            &reader,
            wal_bytes,
            map,
            incremental,
            workspaces,
            timestamp_ms,
        );
    }

    fn encode_database_snapshot(
        self: *Session,
        workspaces: *Workspaces,
        timestamp_ms: i64,
    ) Error!u32 {
        const page_count_value = try self.query_int64("PRAGMA page_count", 0);
        if (page_count_value <= 0) return error.PageLimitExceeded;
        const page_count = std.math.cast(u32, page_count_value) orelse
            return error.PageLimitExceeded;
        if (page_count > self.wal_limits.max_pages) return error.PageLimitExceeded;
        const next_txid = std.math.add(u64, self.position.txid.value, 1) catch
            return error.InvalidTXIDRange;
        const identity = ltx.FileIdentity{
            .min_txid = ltx.TXID.init(next_txid),
            .max_txid = ltx.TXID.init(next_txid),
        };
        var write_session: ?object.WriteSession = if (self.client.supports_write_sessions())
            try self.client.begin_write(0, identity, timestamp_ms)
        else
            null;
        errdefer if (write_session) |*active| active.abort();
        var sink = ltx.SliceWriter.init(workspaces.output_storage);
        var encoder = try ltx.Encoder.init(
            .v3,
            self.codec_limits,
            if (write_session) |*active| active.writer() else sink.writer(),
            workspaces.compressed_workspace,
            workspaces.compression_workspace,
            workspaces.index_workspace,
        );
        try encoder.write_header(snapshot_header(self, identity, timestamp_ms, page_count));
        const written = try self.encode_database_pages(
            &encoder,
            page_count,
            workspaces.page_workspace,
        );
        const verified = try encoder.finish(ltx.Checksum.init(0));
        if (write_session) |*active| try active.finish() else try self.client.write(0, identity, timestamp_ms, sink.written());
        self.record_database_snapshot(verified, page_count);
        return written;
    }

    fn encode_database_pages(
        self: *Session,
        encoder: *ltx.Encoder,
        page_count: u32,
        page_workspace: []u8,
    ) Error!u32 {
        const lock_page = try ltx.lock_page_number(self.page_size);
        var written: u32 = 0;
        var page_number: u32 = 1;
        while (page_number <= page_count) : (page_number += 1) {
            if (page_number == lock_page) continue;
            try self.read_database_page(page_number, page_workspace);
            try encoder.write_page(page_number, page_workspace[0..self.page_size]);
            written += 1;
        }
        return written;
    }

    fn record_database_snapshot(
        self: *Session,
        verified: ltx.VerifiedLTX,
        page_count: u32,
    ) void {
        self.position = verified.post_apply_position();
        self.segment_salt = .{ .salt_1 = 0, .salt_2 = 0 };
        self.segment_end_offset_bytes = 0;
        self.segment_commit_pages = page_count;
        self.segment_restarted = false;
        self.last_wal_bytes = 0;
        self.last_wal_frame_count = 0;
    }

    fn read_wal(self: *Session, storage: []u8) Error![]const u8 {
        var file = self.dir.openFile(
            self.io,
            self.wal_path[0..self.wal_path_bytes],
            .{},
        ) catch return error.WALMissing;
        defer file.close(self.io);
        const stat = file.stat(self.io) catch return error.WALTooLarge;
        const size = std.math.cast(usize, stat.size) orelse return error.WALTooLarge;
        if (size > storage.len) return error.WALTooLarge;
        const read = file.readPositionalAll(self.io, storage[0..size], 0) catch
            return error.WALTooLarge;
        if (read != size) return error.WALTooLarge;
        return storage[0..size];
    }

    fn encode_and_publish(
        self: *Session,
        reader: *wal.Reader,
        wal_bytes: []const u8,
        map: wal.PageMap,
        incremental: bool,
        workspaces: *Workspaces,
        timestamp_ms: i64,
    ) Error!u32 {
        const next_txid = std.math.add(u64, self.position.txid.value, 1) catch
            return error.InvalidTXIDRange;
        const identity = ltx.FileIdentity{
            .min_txid = ltx.TXID.init(next_txid),
            .max_txid = ltx.TXID.init(next_txid),
        };
        const header = try self.capture_header(reader, wal_bytes.len, map, identity, timestamp_ms);
        const wal_size_bytes = std.math.cast(u64, wal_bytes.len) orelse
            return error.WALTooLarge;
        const wal_frame_count = try committed_frame_count(reader, map);
        var write_session: ?object.WriteSession = if (self.client.supports_write_sessions())
            try self.client.begin_write(0, identity, timestamp_ms)
        else
            null;
        errdefer if (write_session) |*active| active.abort();
        var sink = ltx.SliceWriter.init(workspaces.output_storage);
        var encoder = try ltx.Encoder.init(
            .v3,
            self.codec_limits,
            if (write_session) |*active| active.writer() else sink.writer(),
            workspaces.compressed_workspace,
            workspaces.compression_workspace,
            workspaces.index_workspace,
        );
        try encoder.write_header(header);
        const written = try self.encode_pages(
            &encoder,
            wal_bytes,
            map,
            incremental,
            workspaces.page_workspace,
        );
        const verified = try encoder.finish(ltx.Checksum.init(0));
        if (write_session) |*active| {
            try active.finish();
        } else {
            try self.client.write(0, identity, timestamp_ms, sink.written());
        }
        self.record_published(reader, map, verified, wal_size_bytes, wal_frame_count);
        return written;
    }

    fn capture_header(
        self: *const Session,
        reader: *const wal.Reader,
        wal_size: usize,
        map: wal.PageMap,
        identity: ltx.FileIdentity,
        timestamp_ms: i64,
    ) Error!ltx.Header {
        const has_segment = map.end_offset_bytes != 0;
        return .{
            .flags = ltx.header_flag_no_checksum,
            .page_size = self.page_size,
            .commit = map.commit_pages,
            .min_txid = identity.min_txid,
            .max_txid = identity.max_txid,
            .timestamp_ms = timestamp_ms,
            .pre_apply_checksum = ltx.Checksum.init(0),
            // Litestream records the scan end even for snapshots; an empty
            // committed region carries no segment identity at all.
            .wal_offset = std.math.cast(i64, map.end_offset_bytes) orelse
                return error.WALTooLarge,
            .wal_size = if (has_segment)
                std.math.cast(i64, wal_size) orelse return error.WALTooLarge
            else
                0,
            .wal_salt_1 = if (has_segment) reader.header().salt_1 else 0,
            .wal_salt_2 = if (has_segment) reader.header().salt_2 else 0,
            .node_id = 0,
        };
    }

    fn encode_pages(
        self: *Session,
        encoder: *ltx.Encoder,
        wal_bytes: []const u8,
        map: wal.PageMap,
        incremental: bool,
        page_workspace: []u8,
    ) Error!u32 {
        const page_size: usize = self.page_size;
        const lock_page = try ltx.lock_page_number(self.page_size);
        var written: u32 = 0;
        var page_number: u32 = 1;
        while (page_number <= map.commit_pages) : (page_number += 1) {
            if (page_number == lock_page) continue;
            const entry = find_page(map.pages, page_number);
            if (incremental) {
                const fresh = entry != null and
                    entry.?.frame_offset_bytes >= self.segment_end_offset_bytes;
                const grown = page_number > self.segment_commit_pages;
                if (!fresh and !grown) continue;
            }
            if (entry) |found| {
                const start: usize = @intCast(
                    found.frame_offset_bytes + wal.frame_header_size_bytes,
                );
                const page = wal_bytes[start..][0..page_size];
                try encoder.write_page(page_number, page);
            } else {
                try self.read_database_page(page_number, page_workspace);
                try encoder.write_page(page_number, page_workspace[0..page_size]);
            }
            written += 1;
        }
        return written;
    }

    fn record_published(
        self: *Session,
        reader: *const wal.Reader,
        map: wal.PageMap,
        verified: ltx.VerifiedLTX,
        wal_size_bytes: u64,
        wal_frame_count: u64,
    ) void {
        self.position = verified.post_apply_position();
        self.segment_salt = .{
            .salt_1 = reader.header().salt_1,
            .salt_2 = reader.header().salt_2,
        };
        self.segment_end_offset_bytes = map.end_offset_bytes;
        self.segment_commit_pages = map.commit_pages;
        self.segment_restarted = false;
        self.last_wal_bytes = wal_size_bytes;
        self.last_wal_frame_count = wal_frame_count;
    }

    fn read_database_page(self: *Session, page_number: u32, destination: []u8) Error!void {
        const offset = std.math.mul(u64, page_number - 1, self.page_size) catch
            return error.DatabasePageReadFailure;
        var file = self.dir.openFile(
            self.io,
            self.database_path[0..self.database_path_bytes],
            .{},
        ) catch return error.DatabasePageReadFailure;
        defer file.close(self.io);
        const read = file.readPositionalAll(
            self.io,
            destination[0..self.page_size],
            offset,
        ) catch return error.DatabasePageReadFailure;
        if (read != self.page_size) return error.DatabasePageReadFailure;
    }

    fn query_int64(self: *Session, sql: [*:0]const u8, default: i64) Error!i64 {
        var statement: ?*anyopaque = null;
        if (sqlite.sqlite3_prepare_v2(self.db, sql, -1, &statement, null) != sqlite_ok) {
            return error.SQLitePrepareFailure;
        }
        defer _ = sqlite.sqlite3_finalize(statement);
        const step = sqlite.sqlite3_step(statement);
        if (step == sqlite_done) return default;
        if (step != sqlite_row) {
            return switch (step) {
                sqlite_busy => error.SQLiteBusy,
                else => error.SQLiteStepFailure,
            };
        }
        return sqlite.sqlite3_column_int64(statement, 0);
    }

    /// Closes the SQLite connection. Use this instead of dropping the value.
    pub fn finish(self: *Session) void {
        if (self.db) |db| {
            _ = sqlite.sqlite3_close_v2(db);
            self.db = null;
        }
    }

    /// Last SQLite result code, for diagnostics after a failure.
    pub fn last_sqlite_code(self: *const Session) c_int {
        return sqlite.sqlite3_errcode(self.db);
    }
};

fn find_page(pages: []const wal.PageMapEntry, page_number: u32) ?wal.PageMapEntry {
    for (pages) |entry| {
        if (entry.page_number == page_number) return entry;
    }
    return null;
}

const CheckpointProgress = struct {
    busy: i64,
    log_frames: i64,
    checkpointed_frames: i64,

    fn complete(self: CheckpointProgress) bool {
        return self.busy == 0 and self.log_frames >= 0 and
            self.log_frames == self.checkpointed_frames;
    }
};

fn sqlite_step_error(result: c_int) Error {
    return switch (result) {
        sqlite_busy => error.SQLiteBusy,
        else => error.SQLiteStepFailure,
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

fn elapsed_milliseconds(now_ms: i64, previous_ms: i64) Error!u64 {
    const elapsed = @as(i128, now_ms) - @as(i128, previous_ms);
    if (elapsed < 0) return error.TimestampRegression;
    return std.math.cast(u64, elapsed) orelse return error.TimestampRegression;
}

fn committed_frame_count(reader: *const wal.Reader, map: wal.PageMap) Error!u64 {
    if (map.end_offset_bytes == 0) return 0;
    const payload_bytes = std.math.sub(
        u64,
        map.end_offset_bytes,
        wal.header_size_bytes,
    ) catch return error.InvalidOffset;
    const frame_size_bytes = reader.frame_size_bytes();
    if (payload_bytes % frame_size_bytes != 0) return error.InvalidOffset;
    return payload_bytes / frame_size_bytes;
}

fn snapshot_header(
    session: *const Session,
    identity: ltx.FileIdentity,
    timestamp_ms: i64,
    page_count: u32,
) ltx.Header {
    return .{
        .flags = ltx.header_flag_no_checksum,
        .page_size = session.page_size,
        .commit = page_count,
        .min_txid = identity.min_txid,
        .max_txid = identity.max_txid,
        .timestamp_ms = timestamp_ms,
        .pre_apply_checksum = ltx.Checksum.init(0),
        .wal_offset = 0,
        .wal_size = 0,
        .wal_salt_1 = 0,
        .wal_salt_2 = 0,
        .node_id = 0,
    };
}
