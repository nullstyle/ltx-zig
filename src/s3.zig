//! S3-backed `ltx_object` client.
//!
//! Implements the object-client contract against S3-compatible stores using
//! path-style requests and AWS Signature Version 4, at the granularity this
//! milestone covers: single-request `PutObject` with the
//! `litestream-timestamp` metadata header, ranged `GetObject`, per-object
//! `DeleteObject`, paginated `ListObjectsV2` with `start-after` seek, and
//! bucket creation. Transactional write sessions stay in one caller-owned
//! buffer for small objects and switch automatically to multipart upload only
//! when the stream exceeds that buffer. Keys follow the Litestream object-store
//! layout `{prefix}/{level:04x}/{min}-{max}.ltx`. The concrete client also
//! exposes bounded multipart upload, signed conditional writes, TLS, and
//! virtual-host addressing without weakening the storage-neutral object
//! contract.
//!
//! Object payloads, listings, and all signing scratch live in fixed
//! caller-owned buffers. The standard-library HTTP transport is the one
//! allocation point: it allocates pooled connections from the allocator
//! provided at initialization and nothing else allocates. The clock is
//! injected — no ambient time reads.
//!
//! S3 publication is remote: after request delivery begins, a transport error
//! can hide either a committed or rejected write. Conditional methods and
//! transactional publication, including multipart completion, surface
//! `PublicationIndeterminate`, so the host must reconcile the object identity
//! before it advances a durable position or discards source objects.
//!
//! The gate for this backend is `mise run s3-integration`, which starts a
//! local MinIO server and runs the backend-agnostic conformance suite
//! against it.

const std = @import("std");
const ltx = @import("ltx");
const object = @import("ltx_object");

pub const Error = object.Error;

/// Conditional publication can become indeterminate after request delivery
/// starts: a transport failure may hide either a committed or rejected write.
/// Callers must reconcile the object generation before another fenced write.
pub const ConditionalWriteError = Error || error{PublicationIndeterminate};
pub const InitError = Error || error{InvalidConfiguration};

/// At most eight S3 keys are requested per page. With S3's 1,024-byte key
/// limit and worst-case XML entity expansion, this leaves room in the fixed
/// 64 KiB response workspace for every Contents field and page envelope.
pub const max_list_keys_per_page: u32 = 8;

/// Why a request is being considered for retry.
pub const RetryCause = union(enum) {
    /// The transport failed before a complete response arrived.
    transport,
    /// The store answered with a retryable HTTP status (5xx or 429).
    status: u16,
};

/// Caller-injected retry policy. Retries apply to transport failures and
/// to retryable statuses on idempotent methods only (GET, HEAD, DELETE, and
/// unconditional PUT). Conditional PUT and POST requests are never retried.
/// Transactional publication may retry a definite pre-send transport failure,
/// but never retries after delivery begins or after a response status arrives.
/// Delay selection and sleeping are both injected so the module never reads
/// an ambient clock; hosts encode jitter, caps, cancellation, and the actual
/// wait in these callbacks.
pub const RetryPolicy = struct {
    context: *anyopaque,
    next_delay_ms_fn: *const fn (context: *anyopaque, attempt: u32, cause: RetryCause) ?u64,
    sleep_ms_fn: *const fn (context: *anyopaque, delay_ms: u64) Error!void,
    /// Total attempts including the first.
    max_attempts: u32 = 3,

    fn sleep_ms(self: RetryPolicy, delay_ms: u64) Error!void {
        return self.sleep_ms_fn(self.context, delay_ms);
    }
};

/// The conditional header applied to a request. All conditional headers are
/// signed, so the same variant feeds the canonical request.
pub const Conditional = union(enum) {
    none,
    /// `If-None-Match: *` — succeed only when the key is absent.
    create_only,
    /// `If-Match: <etag>` — succeed only when the stored ETag equals the
    /// given one, quotes included.
    match_etag: []const u8,
};

/// Injected wall clock returning Unix milliseconds.
pub const Clock = struct {
    context: *anyopaque,
    now_ms_fn: *const fn (context: *anyopaque) u64,

    pub fn now_ms(self: Clock) u64 {
        return self.now_ms_fn(self.context);
    }
};

pub const Config = struct {
    /// Endpoint host; the client connects over plain HTTP unless
    /// `use_tls` is set.
    host: []const u8,
    port: u16,
    /// Bucket name; limited to characters that are safe in a path segment.
    bucket: []const u8,
    region: []const u8 = "us-east-1",
    access_key: []const u8,
    secret_key: []const u8,
    /// Address the bucket as a host-name prefix (`bucket.host`) instead of
    /// a path prefix. Some stores require this; MinIO defaults to path
    /// style. The bucket name must be valid DNS material.
    virtual_host: bool = false,
    /// Connect with TLS (HTTPS). The standard-library client validates
    /// the server certificate against `ca_file` when provided, otherwise
    /// against the system bundle.
    use_tls: bool = false,
    /// PEM file with the certificate authority for this endpoint.
    /// Relative paths resolve against the process working directory.
    ca_file: ?[]const u8 = null,
    /// Key prefix under the bucket; may be empty.
    prefix: []const u8 = "",
    clock: Clock,
    /// Maximum keys requested per listing page. Must be in
    /// `1...max_list_keys_per_page` so every response stays within the fixed
    /// XML workspace under the S3 key-size limit.
    max_keys_per_page: u32 = max_list_keys_per_page,
    /// Maximum remote pages consumed by one `list` call, including pages that
    /// contain only unrelated or malformed keys. Must be nonzero.
    max_listing_pages: u32 = 4096,
    /// Optional retry policy for transient transport failures and
    /// retryable statuses on idempotent requests.
    retry: ?RetryPolicy = null,
};

/// One in-flight multipart upload. A client tracks a single upload at a
/// time; part bytes stream through the send workspace one part at a time,
/// so an object bounded by `max_multipart_parts * send_workspace.len` never
/// needs to exist whole.
pub const MultipartState = struct {
    level: u8,
    identity: ltx.FileIdentity,
    upload_id_bytes: usize = 0,
    upload_id: [192]u8 = undefined,
    /// ETag per completed part, indexed by part number minus one.
    part_count: u32 = 0,
    etag_lengths: [max_multipart_parts]u8 = @splat(0),
    etags: [max_multipart_parts][64]u8 = @splat(@splat(0)),
    part_sizes: [max_multipart_parts]u64 = @splat(0),
};

pub const max_multipart_parts = 512;
pub const min_multipart_part_bytes = 5 * 1024 * 1024;

const MultipartOwner = enum {
    manual,
    write_session,
};

const StreamingWriteState = struct {
    level: u8,
    identity: ltx.FileIdentity,
    created_at_ms: i64,
    buffered_bytes: usize = 0,
    total_bytes: u64 = 0,
};

const amz_date_bytes = 16;
const sha256_hex_bytes = 64;
const empty_payload_sha256 = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";

/// The S3 object client. Stateful and single-owner: keep it at a stable
/// address while the derived `Client` is in use. `send_workspace` is the
/// mutable staging region for outgoing object bytes, sized for the largest
/// single-request object or multipart part.
pub const S3Client = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    config: Config,
    http: std.http.Client,
    send_workspace: []u8,
    path_workspace: [1024]u8 = undefined,
    query_workspace: [1024]u8 = undefined,
    canonical_workspace: [4096]u8 = undefined,
    string_to_sign_workspace: [512]u8 = undefined,
    authorization_workspace: [512]u8 = undefined,
    redirect_buffer: [1024]u8 = undefined,
    transfer_buffer: [16 * 1024]u8 = undefined,
    xml_workspace: [64 * 1024]u8 = undefined,
    key_slices: [max_list_keys_per_page][]const u8 = undefined,
    size_values: [max_list_keys_per_page]u64 = undefined,
    token_workspace: [256]u8 = undefined,
    etag_workspace: [128]u8 = undefined,
    multipart: ?MultipartState = null,
    multipart_owner: ?MultipartOwner = null,
    write_session: ?StreamingWriteState = null,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        config: Config,
        send_workspace: []u8,
    ) InitError!S3Client {
        if (config.max_keys_per_page == 0 or
            config.max_listing_pages == 0 or
            config.max_keys_per_page > max_list_keys_per_page)
        {
            return error.InvalidConfiguration;
        }
        var self = S3Client{
            .allocator = allocator,
            .io = io,
            .config = config,
            .http = .{ .allocator = allocator, .io = io },
            .send_workspace = send_workspace,
        };
        errdefer self.http.deinit();
        if (config.use_tls) {
            const now = timestamp_from_unix_ms(config.clock.now_ms());
            if (config.ca_file) |path| {
                self.http.ca_bundle.addCertsFromFilePath(
                    allocator,
                    io,
                    now,
                    .cwd(),
                    path,
                ) catch return error.StorageFailure;
            } else {
                self.http.ca_bundle.rescan(allocator, io, now) catch
                    return error.StorageFailure;
            }
            // Pre-setting `now` stops the first TLS request from reading the
            // ambient clock and replacing the caller-selected bundle.
            self.http.now = now;
        }
        return self;
    }

    pub fn deinit(self: *S3Client) void {
        if (self.write_session != null) abort_write_session(self);
        if (self.multipart_owner) |owner| {
            self.abort_multipart_owned(owner) catch {};
        }
        self.http.deinit();
    }

    pub fn client(self: *S3Client) object.Client {
        return .{
            .context = self,
            .list_fn = list,
            .read_range_fn = read_range,
            .write_fn = write,
            .begin_write_fn = begin_write,
            .delete_fn = delete,
        };
    }

    /// Creates the bucket when absent; an already-owned bucket is success.
    pub fn ensure_bucket(self: *S3Client) Error!void {
        const outcome = try self.perform(.PUT, "/", "", .{});
        switch (outcome.status) {
            .ok, .conflict => {},
            else => return error.StorageFailure,
        }
    }

    /// Builds the raw object key for one level and identity.
    fn key_path(
        self: *S3Client,
        level: u8,
        identity: ltx.FileIdentity,
    ) Error![]const u8 {
        if (level > ltx.max_level) return error.InvalidLevel;
        var offset: usize = 0;
        try append_key_part(&self.path_workspace, &offset, "/");
        try append_key_part(&self.path_workspace, &offset, self.config.prefix);
        if (self.config.prefix.len > 0) {
            try append_key_part(&self.path_workspace, &offset, "/");
        }
        var level_name: [4]u8 = undefined;
        try append_key_part(
            &self.path_workspace,
            &offset,
            ltx.format_object_level_name(level, &level_name) catch
                return error.InvalidLevel,
        );
        try append_key_part(&self.path_workspace, &offset, "/");
        var file_name: [ltx.file_name_bytes]u8 = undefined;
        _ = ltx.format_file_name(identity.min_txid, identity.max_txid, &file_name);
        try append_key_part(&self.path_workspace, &offset, &file_name);
        return self.path_workspace[0..offset];
    }

    fn list(
        context: *anyopaque,
        level: u8,
        seek: ltx.TXID,
        destination: []ltx.FileInfo,
    ) Error![]const ltx.FileInfo {
        const self: *S3Client = @ptrCast(@alignCast(context));
        var count: usize = 0;
        var continuation: ?[]const u8 = null;
        var page_count: u32 = 0;
        while (page_count < self.config.max_listing_pages) : (page_count += 1) {
            const remaining = destination.len - count;
            const configured_page_keys: usize = self.config.max_keys_per_page;
            const page_keys: u32 = if (remaining >= configured_page_keys)
                self.config.max_keys_per_page
            else
                @intCast(remaining + 1);
            const query = try build_list_query(
                &self.query_workspace,
                page_keys,
                level,
                seek,
                self.config.prefix,
                continuation,
            );
            const outcome = try self.perform(.GET, "/", query, .{
                .body_destination = &self.xml_workspace,
            });
            if (outcome.status != .ok) return error.StorageFailure;
            const page = try self.parse_list_page(outcome.bytes);
            for (page.keys, page.sizes) |key, size_bytes| {
                const name = basename(key) orelse continue;
                const identity = ltx.parse_file_name(name) catch continue;
                if (identity.min_txid.value < seek.value) continue;
                if (count == destination.len) return error.ListingCapacityExceeded;
                destination[count] = .{
                    .level = level,
                    .min_txid = identity.min_txid,
                    .max_txid = identity.max_txid,
                    .size_bytes = size_bytes,
                };
                count += 1;
            }
            if (!page.truncated) break;
            continuation = page.next_token orelse return error.StorageFailure;
        } else {
            return error.ListingPageLimitExceeded;
        }
        const listed = destination[0..count];
        std.sort.pdq(ltx.FileInfo, listed, {}, file_info_before);
        return listed;
    }

    fn read_range(
        context: *anyopaque,
        info: ltx.FileInfo,
        offset_bytes: u64,
        destination: []u8,
    ) Error!void {
        const self: *S3Client = @ptrCast(@alignCast(context));
        if (destination.len == 0) return;
        const length_bytes = std.math.cast(u64, destination.len) orelse
            return error.InvalidReadRange;
        const end_exclusive_bytes = std.math.add(
            u64,
            offset_bytes,
            length_bytes,
        ) catch return error.InvalidReadRange;
        if (end_exclusive_bytes > info.size_bytes) return error.InvalidReadRange;
        const end_bytes = end_exclusive_bytes - 1;
        const key = try self.key_path(info.level, .{
            .min_txid = info.min_txid,
            .max_txid = info.max_txid,
        });
        const outcome = try self.perform(.GET, key, "", .{
            .body_destination = destination,
            .byte_range = .{
                .start_bytes = offset_bytes,
                .end_bytes = end_bytes,
            },
        });
        if (outcome.status == .not_found) return error.ObjectNotFound;
        if (outcome.status == .range_not_satisfiable) return error.ObjectChanged;
        if (outcome.status != .partial_content) return error.StorageFailure;
        const content_range = outcome.content_range orelse
            return error.StorageFailure;
        if (content_range.total_bytes != info.size_bytes) {
            return error.ObjectChanged;
        }
        if (content_range.start_bytes != offset_bytes or
            content_range.end_bytes != end_bytes)
        {
            return error.StorageFailure;
        }
    }

    fn write(
        context: *anyopaque,
        level: u8,
        identity: ltx.FileIdentity,
        created_at_ms: i64,
        bytes: []const u8,
    ) Error!void {
        const self: *S3Client = @ptrCast(@alignCast(context));
        if (self.has_active_write()) return error.InvalidState;
        if (bytes.len > self.send_workspace.len) return error.ObjectTooLarge;
        const key = try self.key_path(level, identity);
        @memcpy(self.send_workspace[0..bytes.len], bytes);
        const outcome = try self.perform(
            .PUT,
            key,
            "",
            .{
                .payload = self.send_workspace[0..bytes.len],
                .metadata_ms = created_at_ms,
            },
        );
        if (outcome.status != .ok) return error.StorageFailure;
    }

    fn begin_write(
        context: *anyopaque,
        level: u8,
        identity: ltx.FileIdentity,
        created_at_ms: i64,
    ) Error!object.WriteSession {
        const self: *S3Client = @ptrCast(@alignCast(context));
        if (self.has_active_write()) return error.InvalidState;
        self.write_session = .{
            .level = level,
            .identity = identity,
            .created_at_ms = created_at_ms,
        };
        return object.WriteSession.init(.{
            .context = self,
            .write_fn = write_session_chunk,
            .finish_fn = finish_write_session,
            .abort_fn = abort_write_session,
        });
    }

    fn write_session_chunk(context: *anyopaque, bytes: []const u8) Error!void {
        const self: *S3Client = @ptrCast(@alignCast(context));
        var state = &(self.write_session orelse return error.InvalidState);
        const count_bytes = std.math.cast(u64, bytes.len) orelse
            return error.ObjectTooLarge;
        const total_bytes = std.math.add(u64, state.total_bytes, count_bytes) catch
            return error.ObjectTooLarge;
        try self.validate_stream_capacity(total_bytes);

        var remaining = bytes;
        var iteration_count: u32 = 0;
        while (remaining.len > 0) : (iteration_count += 1) {
            if (iteration_count >= max_multipart_parts) return error.ObjectTooLarge;
            if (state.buffered_bytes == self.send_workspace.len) {
                try self.flush_write_session_part();
            }
            const available = self.send_workspace.len - state.buffered_bytes;
            const copy_bytes = @min(available, remaining.len);
            @memcpy(
                self.send_workspace[state.buffered_bytes..][0..copy_bytes],
                remaining[0..copy_bytes],
            );
            state.buffered_bytes += copy_bytes;
            remaining = remaining[copy_bytes..];
            if (state.buffered_bytes == self.send_workspace.len and remaining.len > 0) {
                try self.flush_write_session_part();
            }
        }
        state.total_bytes = total_bytes;
    }

    fn validate_stream_capacity(self: *const S3Client, total_bytes: u64) Error!void {
        const buffer_bytes = std.math.cast(u64, self.send_workspace.len) orelse
            return error.ObjectTooLarge;
        if (total_bytes <= buffer_bytes) return;
        if (buffer_bytes < min_multipart_part_bytes) return error.ObjectTooLarge;
        const maximum_bytes = std.math.mul(
            u64,
            buffer_bytes,
            max_multipart_parts,
        ) catch return error.ObjectTooLarge;
        if (total_bytes > maximum_bytes) return error.ObjectTooLarge;
    }

    fn flush_write_session_part(self: *S3Client) Error!void {
        const state = &(self.write_session orelse return error.InvalidState);
        if (state.buffered_bytes < min_multipart_part_bytes) {
            return error.ObjectTooLarge;
        }
        if (self.multipart == null) {
            try self.begin_multipart_owned(
                .write_session,
                state.level,
                state.identity,
                state.created_at_ms,
            );
        }
        const part_number = try self.next_part_number(.write_session);
        try self.upload_buffered_part(
            .write_session,
            part_number,
            state.buffered_bytes,
        );
        state.buffered_bytes = 0;
    }

    fn finish_write_session(context: *anyopaque) Error!void {
        const self: *S3Client = @ptrCast(@alignCast(context));
        const state = &(self.write_session orelse return error.InvalidState);
        if (self.multipart == null) {
            try self.finish_single_put(state);
        } else {
            if (self.multipart_owner != .write_session) return error.InvalidState;
            if (state.buffered_bytes == 0) return error.InvalidState;
            const part_number = try self.next_part_number(.write_session);
            try self.upload_buffered_part(
                .write_session,
                part_number,
                state.buffered_bytes,
            );
            state.buffered_bytes = 0;
            try self.complete_multipart_owned(.write_session);
        }
        self.write_session = null;
    }

    fn finish_single_put(
        self: *S3Client,
        state: *const StreamingWriteState,
    ) Error!void {
        const key = try self.key_path(state.level, state.identity);
        const outcome = try self.perform(
            .PUT,
            key,
            "",
            .{
                .payload = self.send_workspace[0..state.buffered_bytes],
                .metadata_ms = state.created_at_ms,
                .publication = .indeterminate_after_send,
            },
        );
        if (outcome.status != .ok) {
            return publication_status_failure(outcome.status);
        }
    }

    fn abort_write_session(context: *anyopaque) void {
        const self: *S3Client = @ptrCast(@alignCast(context));
        if (self.write_session == null) return;
        if (self.multipart_owner == .write_session) {
            self.abort_multipart_owned(.write_session) catch {};
        }
        self.write_session = null;
    }

    fn has_active_write(self: *const S3Client) bool {
        return self.write_session != null or self.multipart != null;
    }

    /// Begins one multipart upload. The client tracks a single in-flight
    /// upload; part bodies stream through the send workspace one part at a
    /// time, so the object may be far larger than any workspace. Parts must
    /// number from one and rise without gaps; every part except the last
    /// must meet the store's minimum part size (5 MiB on S3 and MinIO).
    pub fn begin_multipart(
        self: *S3Client,
        level: u8,
        identity: ltx.FileIdentity,
        created_at_ms: i64,
    ) Error!void {
        if (self.write_session != null) return error.InvalidState;
        return self.begin_multipart_owned(
            .manual,
            level,
            identity,
            created_at_ms,
        );
    }

    fn begin_multipart_owned(
        self: *S3Client,
        owner: MultipartOwner,
        level: u8,
        identity: ltx.FileIdentity,
        created_at_ms: i64,
    ) Error!void {
        if (self.multipart != null or self.multipart_owner != null) {
            return error.InvalidState;
        }
        const key = try self.key_path(level, identity);
        const query = try build_upload_query(&self.query_workspace, "uploads");
        const outcome = try self.perform(
            .POST,
            key,
            query,
            .{
                .metadata_ms = created_at_ms,
                .body_destination = &self.xml_workspace,
            },
        );
        if (outcome.status != .ok) return error.StorageFailure;
        var state = MultipartState{ .level = level, .identity = identity };
        const id_start = std.mem.indexOf(u8, outcome.bytes, "<UploadId>") orelse
            return error.StorageFailure;
        const value_start = id_start + "<UploadId>".len;
        const value_end = std.mem.indexOfPos(u8, outcome.bytes, value_start, "</UploadId>") orelse
            return error.StorageFailure;
        if (value_end - value_start > state.upload_id.len) return error.StorageFailure;
        @memcpy(state.upload_id[0 .. value_end - value_start], outcome.bytes[value_start..value_end]);
        state.upload_id_bytes = value_end - value_start;
        self.multipart = state;
        self.multipart_owner = owner;
    }

    /// Uploads one part and records its ETag for completion. Part numbers
    /// start at one; consecutive calls may skip nothing.
    pub fn put_part(
        self: *S3Client,
        part_number: u32,
        bytes: []const u8,
    ) Error!void {
        if (self.write_session != null) return error.InvalidState;
        if (bytes.len > self.send_workspace.len) return error.ObjectTooLarge;
        @memcpy(self.send_workspace[0..bytes.len], bytes);
        return self.upload_buffered_part(.manual, part_number, bytes.len);
    }

    fn next_part_number(
        self: *const S3Client,
        owner: MultipartOwner,
    ) Error!u32 {
        const state = &(self.multipart orelse return error.InvalidState);
        if (self.multipart_owner != owner) return error.InvalidState;
        if (state.part_count >= max_multipart_parts) return error.ObjectTooLarge;
        return state.part_count + 1;
    }

    fn upload_buffered_part(
        self: *S3Client,
        owner: MultipartOwner,
        part_number: u32,
        length_bytes: usize,
    ) Error!void {
        var state = &(self.multipart orelse return error.InvalidState);
        if (self.multipart_owner != owner) return error.InvalidState;
        if (part_number == 0 or part_number > max_multipart_parts) {
            return error.ObjectTooLarge;
        }
        if (part_number != state.part_count + 1) return error.InvalidState;
        if (length_bytes > self.send_workspace.len) return error.ObjectTooLarge;
        if (state.part_count > 0 and
            state.part_sizes[state.part_count - 1] < min_multipart_part_bytes)
        {
            return error.InvalidState;
        }
        const key = try self.key_path(state.level, state.identity);
        const query = try build_part_query(
            &self.query_workspace,
            part_number,
            state.upload_id[0..state.upload_id_bytes],
        );
        const outcome = try self.perform(
            .PUT,
            key,
            query,
            .{ .payload = self.send_workspace[0..length_bytes] },
        );
        if (outcome.status != .ok) return error.StorageFailure;
        const etag = outcome.etag orelse return error.StorageFailure;
        if (etag.len > 64) return error.StorageFailure;
        @memcpy(state.etags[state.part_count][0..etag.len], etag);
        state.etag_lengths[state.part_count] = @intCast(etag.len);
        state.part_sizes[state.part_count] = @intCast(length_bytes);
        state.part_count += 1;
    }

    /// Completes the in-flight multipart upload, publishing the object. A
    /// transport failure, retryable status, or invalid acknowledgement after
    /// request delivery begins returns `PublicationIndeterminate` and is never
    /// retried automatically. The caller must reconcile the object identity
    /// before retrying or deleting source state.
    pub fn complete_multipart(self: *S3Client) Error!void {
        if (self.write_session != null) return error.InvalidState;
        return self.complete_multipart_owned(.manual);
    }

    fn complete_multipart_owned(
        self: *S3Client,
        owner: MultipartOwner,
    ) Error!void {
        const state = &(self.multipart orelse return error.InvalidState);
        if (self.multipart_owner != owner) return error.InvalidState;
        if (state.part_count == 0) return error.InvalidState;
        var checked_part: u32 = 0;
        while (checked_part + 1 < state.part_count) : (checked_part += 1) {
            if (state.part_sizes[checked_part] < min_multipart_part_bytes) {
                return error.InvalidState;
            }
        }
        const key = try self.key_path(state.level, state.identity);
        const query = try build_upload_query_with_id(
            &self.query_workspace,
            state.upload_id[0..state.upload_id_bytes],
        );
        var body_offset: usize = 0;
        try append_multipart_xml(&self.xml_workspace, &body_offset, "<CompleteMultipartUpload>");
        var part_number: u32 = 1;
        while (part_number <= state.part_count) : (part_number += 1) {
            const index = part_number - 1;
            const etag = state.etags[index][0..state.etag_lengths[index]];
            var entry: [160]u8 = undefined;
            const text = std.fmt.bufPrint(
                &entry,
                "<Part><PartNumber>{d}</PartNumber><ETag>{s}</ETag></Part>",
                .{ part_number, etag },
            ) catch return error.StorageFailure;
            try append_multipart_xml(&self.xml_workspace, &body_offset, text);
        }
        try append_multipart_xml(&self.xml_workspace, &body_offset, "</CompleteMultipartUpload>");
        var body_buffer: [64 * 1024]u8 = undefined;
        @memcpy(body_buffer[0..body_offset], self.xml_workspace[0..body_offset]);
        const outcome = try self.perform(
            .POST,
            key,
            query,
            .{
                .payload = body_buffer[0..body_offset],
                .body_destination = &self.xml_workspace,
                .publication = .indeterminate_after_send,
            },
        );
        if (outcome.status != .ok) {
            return publication_status_failure(outcome.status);
        }
        validate_complete_multipart_response(outcome.bytes) catch
            return error.PublicationIndeterminate;
        self.multipart = null;
        self.multipart_owner = null;
    }

    /// Aborts the in-flight multipart upload, discarding its parts. A failed
    /// cleanup retains the upload identity so the caller or `deinit` can retry;
    /// all new writes remain blocked until cleanup succeeds.
    pub fn abort_multipart(self: *S3Client) Error!void {
        if (self.write_session != null) return error.InvalidState;
        const owner = self.multipart_owner orelse return error.InvalidState;
        return self.abort_multipart_owned(owner);
    }

    fn abort_multipart_owned(
        self: *S3Client,
        owner: MultipartOwner,
    ) Error!void {
        const state = &(self.multipart orelse return error.InvalidState);
        if (self.multipart_owner != owner) return error.InvalidState;
        const key = try self.key_path(state.level, state.identity);
        const query = try build_upload_query_with_id(
            &self.query_workspace,
            state.upload_id[0..state.upload_id_bytes],
        );
        const outcome = try self.perform(
            .DELETE,
            key,
            query,
            .{},
        );
        if (!abort_status_is_clean(outcome.status)) return error.StorageFailure;
        self.multipart = null;
        self.multipart_owner = null;
    }

    /// Writes one object only when its key is absent, for host-side lease
    /// fencing: the first writer wins and later contenders receive
    /// `ObjectExists`. Uses `If-None-Match: *`, which the store must support.
    /// A failure after delivery begins returns `PublicationIndeterminate` and
    /// is never retried automatically; reconcile the stored generation.
    pub fn put_if_absent(
        self: *S3Client,
        level: u8,
        identity: ltx.FileIdentity,
        created_at_ms: i64,
        bytes: []const u8,
    ) ConditionalWriteError!void {
        if (self.has_active_write()) return error.InvalidState;
        if (level > ltx.max_level) return error.InvalidLevel;
        if (identity.min_txid.value > identity.max_txid.value) {
            return error.InvalidIdentity;
        }
        if (bytes.len > self.send_workspace.len) return error.ObjectTooLarge;
        const key = try self.key_path(level, identity);
        @memcpy(self.send_workspace[0..bytes.len], bytes);
        const outcome = try self.perform_conditional(
            .PUT,
            key,
            "",
            .{
                .payload = self.send_workspace[0..bytes.len],
                .metadata_ms = created_at_ms,
                .conditional = .create_only,
            },
        );
        switch (outcome.status) {
            .ok, .created => {},
            .precondition_failed => return error.ObjectExists,
            else => return conditional_status_failure(outcome.status),
        }
    }

    /// Reads one object's current ETag (quotes included) without fetching
    /// its body. The returned slice lives in client storage until the next
    /// request. Lease renewal composes this with `put_if_match`.
    pub fn object_etag(
        self: *S3Client,
        level: u8,
        identity: ltx.FileIdentity,
    ) Error![]const u8 {
        if (level > ltx.max_level) return error.InvalidLevel;
        if (identity.min_txid.value > identity.max_txid.value) {
            return error.InvalidIdentity;
        }
        const key = try self.key_path(level, identity);
        const outcome = try self.perform(.HEAD, key, "", .{});
        if (outcome.status == .not_found) return error.ObjectNotFound;
        if (outcome.status != .ok) return error.StorageFailure;
        return outcome.etag orelse error.StorageFailure;
    }

    /// Writes one object only when its stored ETag equals `expected_etag`
    /// (as returned by `object_etag`, quotes included). This is the
    /// replace-if-generation primitive for lease renewal: a contender that
    /// renewed between the caller's read and write shifts the ETag and this
    /// call fails with `ETagMismatch`. A failure after delivery begins returns
    /// `PublicationIndeterminate` and is never retried automatically; reconcile
    /// the stored generation before renewal continues.
    pub fn put_if_match(
        self: *S3Client,
        level: u8,
        identity: ltx.FileIdentity,
        created_at_ms: i64,
        bytes: []const u8,
        expected_etag: []const u8,
    ) ConditionalWriteError!void {
        if (self.has_active_write()) return error.InvalidState;
        if (level > ltx.max_level) return error.InvalidLevel;
        if (identity.min_txid.value > identity.max_txid.value) {
            return error.InvalidIdentity;
        }
        if (bytes.len > self.send_workspace.len) return error.ObjectTooLarge;
        const key = try self.key_path(level, identity);
        @memcpy(self.send_workspace[0..bytes.len], bytes);
        const outcome = try self.perform_conditional(
            .PUT,
            key,
            "",
            .{
                .payload = self.send_workspace[0..bytes.len],
                .metadata_ms = created_at_ms,
                .conditional = .{ .match_etag = expected_etag },
            },
        );
        switch (outcome.status) {
            .ok => {},
            .precondition_failed => return error.ETagMismatch,
            else => return conditional_status_failure(outcome.status),
        }
    }

    fn delete(
        context: *anyopaque,
        files: []const ltx.FileInfo,
    ) Error!void {
        const self: *S3Client = @ptrCast(@alignCast(context));
        if (self.has_active_write()) return error.InvalidState;
        for (files) |info| {
            const key = try self.key_path(
                info.level,
                .{ .min_txid = info.min_txid, .max_txid = info.max_txid },
            );
            const outcome = try self.perform(.DELETE, key, "", .{});
            switch (outcome.status) {
                // S3 answers a successful delete with 204 No Content.
                .ok, .no_content, .not_found => {},
                else => return error.StorageFailure,
            }
        }
    }

    const ByteRange = struct {
        start_bytes: u64,
        end_bytes: u64,
    };

    const ContentRange = struct {
        start_bytes: u64,
        end_bytes: u64,
        total_bytes: u64,
    };

    const RequestOptions = struct {
        payload: ?[]u8 = null,
        metadata_ms: ?i64 = null,
        body_destination: ?[]u8 = null,
        conditional: Conditional = .none,
        byte_range: ?ByteRange = null,
        publication: Publication = .definite,
    };

    const Publication = enum {
        definite,
        indeterminate_after_send,
    };

    const Outcome = struct {
        status: std.http.Status,
        /// Response bytes when a body destination was supplied and the status
        /// was OK or an expected partial-content response; otherwise empty.
        bytes: []const u8 = &.{},
        /// The `ETag` response header when present, copied into client
        /// storage and valid until the next request.
        etag: ?[]const u8 = null,
        content_range: ?ContentRange = null,
    };

    /// Signs and performs one request, retrying transient failures when a
    /// policy is configured. The response body, when requested, is read
    /// fully into `body_destination` before the connection returns to the
    /// pool, so the returned bytes stay valid afterwards.
    fn perform(
        self: *S3Client,
        method: std.http.Method,
        key: []const u8,
        query: []const u8,
        options: RequestOptions,
    ) Error!Outcome {
        switch (options.conditional) {
            .none => {},
            .create_only, .match_etag => unreachable,
        }
        const policy = self.config.retry orelse
            return self.perform_once(method, key, query, options);
        var attempt: u32 = 1;
        while (true) : (attempt += 1) {
            const outcome = self.perform_once(
                method,
                key,
                query,
                options,
            ) catch |err| {
                if (err == error.PublicationIndeterminate) return err;
                if (err != error.StorageFailure) return err;
                if (retry_delay(
                    policy,
                    attempt,
                    .transport,
                    method,
                    options.conditional,
                )) |delay| {
                    try policy.sleep_ms(delay);
                    continue;
                }
                return err;
            };
            const retryable = @intFromEnum(outcome.status) >= 500 or
                outcome.status == .too_many_requests;
            if (retryable) {
                if (options.publication == .indeterminate_after_send) {
                    return outcome;
                }
                if (retry_delay(policy, attempt, .{
                    .status = @intFromEnum(outcome.status),
                }, method, options.conditional)) |delay| {
                    try policy.sleep_ms(delay);
                    continue;
                }
            }
            return outcome;
        }
    }

    /// Executes a fenced PUT exactly once. Once sending starts, any transport
    /// failure is conservatively indeterminate because the store may have
    /// committed the conditional write before the response was lost.
    fn perform_conditional(
        self: *S3Client,
        method: std.http.Method,
        key: []const u8,
        query: []const u8,
        options: RequestOptions,
    ) ConditionalWriteError!Outcome {
        std.debug.assert(method == .PUT);
        switch (options.conditional) {
            .none => unreachable,
            .create_only, .match_etag => {},
        }
        std.debug.assert(options.byte_range == null);
        return self.perform_once(method, key, query, options);
    }

    /// Signs and performs exactly one request attempt.
    fn perform_once(
        self: *S3Client,
        method: std.http.Method,
        key: []const u8,
        query: []const u8,
        options: RequestOptions,
    ) ConditionalWriteError!Outcome {
        const now_ms = self.config.clock.now_ms();
        var amz_date: [amz_date_bytes]u8 = undefined;
        try format_amz_date(now_ms, &amz_date);
        // Keep certificate validation and request signing on the same injected
        // wall clock for every new or reused HTTP request.
        self.http.now = timestamp_from_unix_ms(now_ms);
        var payload_hash: [sha256_hex_bytes]u8 = undefined;
        sha256_hex(options.payload orelse "", &payload_hash);

        var timestamp_buffer: [24]u8 = undefined;
        var timestamp_text: []const u8 = "";
        if (options.metadata_ms) |value| {
            timestamp_text = try format_litestream_timestamp(value, &timestamp_buffer);
        }

        var range_buffer: [48]u8 = undefined;
        const range_text: ?[]const u8 = if (options.byte_range) |byte_range|
            std.fmt.bufPrint(&range_buffer, "bytes={d}-{d}", .{
                byte_range.start_bytes,
                byte_range.end_bytes,
            }) catch return error.StorageFailure
        else
            null;

        var path_buffer: [1024]u8 = undefined;
        var host_buffer: [256]u8 = undefined;
        const host_header = if (self.config.virtual_host)
            std.fmt.bufPrint(&host_buffer, "{s}.{s}", .{
                self.config.bucket,
                self.config.host,
            }) catch return error.PathTooLong
        else
            self.config.host;
        const path = if (self.config.virtual_host)
            std.fmt.bufPrint(&path_buffer, "{s}", .{key}) catch return error.PathTooLong
        else
            std.fmt.bufPrint(&path_buffer, "/{s}{s}", .{
                self.config.bucket,
                key,
            }) catch return error.PathTooLong;
        std.debug.assert(key.len >= 1 and key[0] == '/');

        const authorization = try self.sign(
            method,
            key,
            query,
            &amz_date,
            &payload_hash,
            if (options.metadata_ms == null) null else timestamp_text,
            options.conditional,
            range_text,
            host_header,
        );

        var extra_headers: [5]std.http.Header = undefined;
        var extra_count: usize = 0;
        extra_headers[extra_count] = .{
            .name = "x-amz-date",
            .value = &amz_date,
        };
        extra_count += 1;
        extra_headers[extra_count] = .{
            .name = "x-amz-content-sha256",
            .value = &payload_hash,
        };
        extra_count += 1;
        if (options.metadata_ms != null) {
            extra_headers[extra_count] = .{
                .name = "x-amz-meta-litestream-timestamp",
                .value = timestamp_text,
            };
            extra_count += 1;
        }
        switch (options.conditional) {
            .none => {},
            .create_only => {
                extra_headers[extra_count] = .{
                    .name = "if-none-match",
                    .value = "*",
                };
                extra_count += 1;
            },
            .match_etag => |etag| {
                extra_headers[extra_count] = .{
                    .name = "if-match",
                    .value = etag,
                };
                extra_count += 1;
            },
        }
        if (range_text) |text| {
            extra_headers[extra_count] = .{
                .name = "range",
                .value = text,
            };
            extra_count += 1;
        }

        const uri = std.Uri{
            .scheme = if (self.config.use_tls) "https" else "http",
            .host = .{ .raw = host_header },
            .port = self.config.port,
            // Both components are already AWS-URI-encoded; `.raw` would be
            // percent-encoded a second time on the wire.
            .path = .{ .percent_encoded = path },
            .query = if (query.len > 0) .{ .percent_encoded = query } else null,
        };
        var request = self.http.request(method, uri, .{
            .headers = .{
                .authorization = .{ .override = authorization },
                .accept_encoding = .omit,
            },
            .extra_headers = extra_headers[0..extra_count],
        }) catch return error.StorageFailure;
        defer request.deinit();

        if (options.payload) |body| {
            request.sendBodyComplete(body) catch
                return post_send_failure(options);
        } else if (method.requestHasBody()) {
            // PUT without a payload still carries a zero-length body.
            const empty = self.send_workspace[0..0];
            request.sendBodyComplete(empty) catch
                return post_send_failure(options);
        } else {
            request.sendBodiless() catch
                return post_send_failure(options);
        }
        var response = request.receiveHead(&self.redirect_buffer) catch
            return post_send_failure(options);
        const status = response.head.status;
        mark_bodyless_response_complete(&request, method, status);
        var etag: ?[]const u8 = null;
        var content_range: ?ContentRange = null;
        var header_iterator = response.head.iterateHeaders();
        while (header_iterator.next()) |header| {
            if (std.ascii.eqlIgnoreCase(header.name, "etag")) {
                const length = @min(header.value.len, self.etag_workspace.len);
                @memcpy(self.etag_workspace[0..length], header.value[0..length]);
                etag = self.etag_workspace[0..length];
            } else if (status == .partial_content and
                std.ascii.eqlIgnoreCase(header.name, "content-range"))
            {
                if (content_range != null) return error.StorageFailure;
                content_range = try parse_content_range(header.value);
            }
        }
        const readable_status = status == .ok or
            (options.byte_range != null and status == .partial_content);
        if (!readable_status) return .{
            .status = status,
            .etag = etag,
            .content_range = content_range,
        };
        const destination = options.body_destination orelse return .{
            .status = status,
            .etag = etag,
            .content_range = content_range,
        };
        const reader = response.reader(&self.transfer_buffer);
        const bytes = read_bounded_response_body(reader, destination) catch |err| {
            if (options.publication == .indeterminate_after_send) {
                return error.PublicationIndeterminate;
            }
            if (options.byte_range != null and err == error.ObjectTooLarge) {
                return error.StorageFailure;
            }
            return err;
        };
        if (options.byte_range != null and bytes.len != destination.len) {
            return error.StorageFailure;
        }
        return .{
            .status = status,
            .bytes = bytes,
            .etag = etag,
            .content_range = content_range,
        };
    }

    /// Produces the SigV4 authorization header value in
    /// `authorization_workspace` and returns it.
    fn sign(
        self: *S3Client,
        method: std.http.Method,
        key: []const u8,
        query: []const u8,
        amz_date: *const [amz_date_bytes]u8,
        payload_hash: *const [sha256_hex_bytes]u8,
        timestamp_text: ?[]const u8,
        conditional: Conditional,
        range_text: ?[]const u8,
        host_header: []const u8,
    ) Error![]const u8 {
        var canonical_offset: usize = 0;
        const canonical = &self.canonical_workspace;
        try append_canonical(canonical, &canonical_offset, @tagName(method));
        if (self.config.virtual_host) {
            try append_canonical(canonical, &canonical_offset, "\n");
            try append_canonical(canonical, &canonical_offset, key);
        } else {
            try append_canonical(canonical, &canonical_offset, "\n/");
            try append_canonical(canonical, &canonical_offset, self.config.bucket);
            try append_canonical(canonical, &canonical_offset, key);
        }
        try append_canonical(canonical, &canonical_offset, "\n");
        try append_canonical(canonical, &canonical_offset, query);
        var port_buffer: [8]u8 = undefined;
        const port_text = std.fmt.bufPrint(&port_buffer, "{d}", .{
            self.config.port,
        }) catch return error.StorageFailure;
        try append_canonical(canonical, &canonical_offset, "\nhost:");
        try append_canonical(canonical, &canonical_offset, host_header);
        try append_canonical(canonical, &canonical_offset, ":");
        try append_canonical(canonical, &canonical_offset, port_text);
        switch (conditional) {
            .none => {},
            .create_only => {
                try append_canonical(canonical, &canonical_offset, "\nif-none-match:*");
            },
            .match_etag => |etag| {
                try append_canonical(canonical, &canonical_offset, "\nif-match:");
                try append_canonical(canonical, &canonical_offset, etag);
            },
        }
        if (range_text) |text| {
            try append_canonical(canonical, &canonical_offset, "\nrange:");
            try append_canonical(canonical, &canonical_offset, text);
        }
        try append_canonical(
            canonical,
            &canonical_offset,
            "\nx-amz-content-sha256:",
        );
        try append_canonical(canonical, &canonical_offset, payload_hash);
        try append_canonical(canonical, &canonical_offset, "\nx-amz-date:");
        try append_canonical(canonical, &canonical_offset, amz_date);
        if (timestamp_text) |text| {
            try append_canonical(
                canonical,
                &canonical_offset,
                "\nx-amz-meta-litestream-timestamp:",
            );
            try append_canonical(canonical, &canonical_offset, text);
        }

        const conditional_name: ?[]const u8 = switch (conditional) {
            .none => null,
            .create_only => "if-none-match",
            .match_etag => "if-match",
        };
        const signed_headers = signed_headers_text(
            timestamp_text != null,
            conditional_name,
            range_text != null,
        );
        try append_canonical(canonical, &canonical_offset, "\n\n");
        try append_canonical(canonical, &canonical_offset, signed_headers);
        try append_canonical(canonical, &canonical_offset, "\n");
        try append_canonical(canonical, &canonical_offset, payload_hash);

        var canonical_hash: [sha256_hex_bytes]u8 = undefined;
        sha256_hex(canonical[0..canonical_offset], &canonical_hash);

        var scope_buffer: [128]u8 = undefined;
        const scope = std.fmt.bufPrint(&scope_buffer, "{s}/{s}/s3/aws4_request", .{
            amz_date[0..8],
            self.config.region,
        }) catch return error.StorageFailure;
        const string_to_sign = std.fmt.bufPrint(
            &self.string_to_sign_workspace,
            "AWS4-HMAC-SHA256\n{s}\n{s}\n{s}",
            .{ amz_date, scope, &canonical_hash },
        ) catch return error.StorageFailure;

        var key_buffer: [160]u8 = undefined;
        const secret = std.fmt.bufPrint(&key_buffer, "AWS4{s}", .{
            self.config.secret_key,
        }) catch return error.StorageFailure;
        var k_date: [32]u8 = undefined;
        HmacSha256.create(&k_date, amz_date[0..8], secret);
        var k_region: [32]u8 = undefined;
        HmacSha256.create(&k_region, self.config.region, &k_date);
        var k_service: [32]u8 = undefined;
        HmacSha256.create(&k_service, "s3", &k_region);
        var k_signing: [32]u8 = undefined;
        HmacSha256.create(&k_signing, "aws4_request", &k_service);
        var signature: [sha256_hex_bytes]u8 = undefined;
        sha256_hmac_hex(&k_signing, string_to_sign, &signature);

        const authorization = std.fmt.bufPrint(
            &self.authorization_workspace,
            "AWS4-HMAC-SHA256 Credential={s}/{s}, SignedHeaders={s}, Signature={s}",
            .{ self.config.access_key, scope, signed_headers, &signature },
        ) catch return error.StorageFailure;
        return authorization;
    }

    fn parse_content_range(value: []const u8) Error!ContentRange {
        if (!std.mem.startsWith(u8, value, "bytes ")) {
            return error.StorageFailure;
        }
        const fields = value["bytes ".len..];
        const slash = std.mem.indexOfScalar(u8, fields, '/') orelse
            return error.StorageFailure;
        if (std.mem.indexOfScalar(u8, fields[slash + 1 ..], '/') != null) {
            return error.StorageFailure;
        }
        const interval = fields[0..slash];
        const dash = std.mem.indexOfScalar(u8, interval, '-') orelse
            return error.StorageFailure;
        if (std.mem.indexOfScalar(u8, interval[dash + 1 ..], '-') != null) {
            return error.StorageFailure;
        }
        const start_bytes = try parse_decimal_u64(interval[0..dash]);
        const end_bytes = try parse_decimal_u64(interval[dash + 1 ..]);
        const total_bytes = try parse_decimal_u64(fields[slash + 1 ..]);
        if (start_bytes > end_bytes or end_bytes >= total_bytes) {
            return error.StorageFailure;
        }
        return .{
            .start_bytes = start_bytes,
            .end_bytes = end_bytes,
            .total_bytes = total_bytes,
        };
    }

    fn parse_decimal_u64(value: []const u8) Error!u64 {
        if (value.len == 0) return error.StorageFailure;
        for (value) |byte| {
            if (!std.ascii.isDigit(byte)) return error.StorageFailure;
        }
        return std.fmt.parseInt(u64, value, 10) catch
            error.StorageFailure;
    }

    const ListPage = struct {
        keys: []const []const u8,
        sizes: []const u64,
        truncated: bool,
        next_token: ?[]const u8,
    };

    /// Scans one ListObjectsV2 page for key entries, the truncation flag,
    /// and the continuation token (copied into `token_workspace` so it
    /// survives the next response reusing the XML workspace).
    fn parse_list_page(self: *S3Client, xml: []const u8) Error!ListPage {
        var count: usize = 0;
        var cursor: usize = 0;
        while (std.mem.indexOfPos(u8, xml, cursor, "<Contents>")) |contents_start| {
            const contents_end = std.mem.indexOfPos(
                u8,
                xml,
                contents_start + "<Contents>".len,
                "</Contents>",
            ) orelse return error.StorageFailure;
            const key_start = std.mem.indexOfPos(u8, xml, contents_start, "<Key>") orelse
                return error.StorageFailure;
            const value_start = key_start + "<Key>".len;
            const value_end = std.mem.indexOfPos(u8, xml, value_start, "</Key>") orelse
                return error.StorageFailure;
            const size_start = std.mem.indexOfPos(u8, xml, value_end, "<Size>") orelse
                return error.StorageFailure;
            const size_value_start = size_start + "<Size>".len;
            const size_value_end = std.mem.indexOfPos(u8, xml, size_value_start, "</Size>") orelse
                return error.StorageFailure;
            if (value_end > contents_end or size_value_end > contents_end) {
                return error.StorageFailure;
            }
            if (count == self.key_slices.len) return error.StorageFailure;
            self.key_slices[count] = xml[value_start..value_end];
            self.size_values[count] = std.fmt.parseInt(
                u64,
                xml[size_value_start..size_value_end],
                10,
            ) catch return error.StorageFailure;
            count += 1;
            cursor = contents_end + "</Contents>".len;
        }
        const truncated_text = xml_text(
            xml,
            "<IsTruncated>",
            "</IsTruncated>",
        ) orelse return error.StorageFailure;
        const truncated = if (std.mem.eql(u8, truncated_text, "true"))
            true
        else if (std.mem.eql(u8, truncated_text, "false"))
            false
        else
            return error.StorageFailure;
        var next_token: ?[]const u8 = null;
        if (truncated) {
            const encoded = xml_text(
                xml,
                "<NextContinuationToken>",
                "</NextContinuationToken>",
            ) orelse return error.StorageFailure;
            next_token = try decode_xml_text(encoded, &self.token_workspace);
        }
        return .{
            .keys = self.key_slices[0..count],
            .sizes = self.size_values[0..count],
            .truncated = truncated,
            .next_token = next_token,
        };
    }
};

const Sha256 = std.crypto.hash.sha2.Sha256;
const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;

fn sha256_hex(bytes: []const u8, out: *[sha256_hex_bytes]u8) void {
    var digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(bytes, &digest, .{});
    _ = std.fmt.bufPrint(out, "{x}", .{&digest}) catch unreachable;
}

fn sha256_hmac_hex(key: *const [32]u8, message: []const u8, out: *[sha256_hex_bytes]u8) void {
    var digest: [32]u8 = undefined;
    HmacSha256.create(&digest, message, key);
    _ = std.fmt.bufPrint(out, "{x}", .{&digest}) catch unreachable;
}

fn timestamp_from_unix_ms(unix_ms: u64) std.Io.Timestamp {
    const nanoseconds = @as(i96, @intCast(unix_ms)) *
        @as(i96, std.time.ns_per_ms);
    return std.Io.Timestamp.fromNanoseconds(nanoseconds);
}

fn format_amz_date(now_ms: u64, out: *[amz_date_bytes]u8) Error!void {
    const total_seconds = now_ms / 1000;
    const days: i64 = @intCast(total_seconds / 86_400);
    const day_seconds = total_seconds % 86_400;
    const civil = civil_from_days(days);
    if (civil.year < 0 or civil.year > 9999) return error.InvalidTimestamp;
    _ = std.fmt.bufPrint(out, "{d:0>4}{d:0>2}{d:0>2}T{d:0>2}{d:0>2}{d:0>2}Z", .{
        @as(u16, @intCast(civil.year)),
        civil.month,
        civil.day,
        day_seconds / 3600,
        (day_seconds % 3600) / 60,
        day_seconds % 60,
    }) catch return error.InvalidTimestamp;
}

/// Litestream stores the LTX header timestamp as UTC RFC3339Nano metadata.
/// LTX timestamps have millisecond precision, so the fractional part is at
/// most three digits and trailing zeroes are omitted like Go's formatter.
fn format_litestream_timestamp(
    timestamp_ms: i64,
    out: *[24]u8,
) Error![]const u8 {
    const total_seconds = @divFloor(timestamp_ms, 1000);
    const days = @divFloor(total_seconds, 86_400);
    const day_seconds = @mod(total_seconds, 86_400);
    const millisecond: u16 = @intCast(@mod(timestamp_ms, 1000));
    const civil = civil_from_days(days);
    if (civil.year < 0 or civil.year > 9999) return error.InvalidTimestamp;

    const prefix = std.fmt.bufPrint(out, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}", .{
        @as(u16, @intCast(civil.year)),
        civil.month,
        civil.day,
        @as(u32, @intCast(@divFloor(day_seconds, 3600))),
        @as(u32, @intCast(@divFloor(@mod(day_seconds, 3600), 60))),
        @as(u32, @intCast(@mod(day_seconds, 60))),
    }) catch return error.StorageFailure;
    const tail = if (millisecond == 0)
        std.fmt.bufPrint(out[prefix.len..], "Z", .{}) catch return error.StorageFailure
    else if (@mod(millisecond, 100) == 0)
        std.fmt.bufPrint(out[prefix.len..], ".{d}Z", .{@divExact(millisecond, 100)}) catch
            return error.StorageFailure
    else if (@mod(millisecond, 10) == 0)
        std.fmt.bufPrint(out[prefix.len..], ".{d:0>2}Z", .{@divExact(millisecond, 10)}) catch
            return error.StorageFailure
    else
        std.fmt.bufPrint(out[prefix.len..], ".{d:0>3}Z", .{millisecond}) catch
            return error.StorageFailure;
    return out[0 .. prefix.len + tail.len];
}

const CivilDate = struct { year: i64, month: u32, day: u32 };

/// Days-since-epoch to Gregorian year, month, day (Howard Hinnant's
/// `civil_from_days`).
fn civil_from_days(days: i64) CivilDate {
    const z = days + 719_468;
    const era = @divFloor(if (z >= 0) z else z - 146_096, 146_097);
    const era_day: u64 = @intCast(z - era * 146_097);
    const year_of_era = (era_day - era_day / 1460 + era_day / 36_524 -
        era_day / 146_096) / 365;
    const year = @as(i64, @intCast(year_of_era)) + era * 400;
    const day_of_year = era_day - (365 * year_of_era + year_of_era / 4 -
        year_of_era / 100);
    const mp = (5 * day_of_year + 2) / 153;
    const day = day_of_year - (153 * mp + 2) / 5 + 1;
    const month = if (mp < 10) mp + 3 else mp - 9;
    return .{
        .year = if (month <= 2) year + 1 else year,
        .month = @intCast(month),
        .day = @intCast(day),
    };
}

/// Builds the canonical (and request) query for one listing page. Parameters
/// are emitted in the byte order AWS requires for signing.
fn build_list_query(
    destination: []u8,
    max_keys: u32,
    level: u8,
    seek: ltx.TXID,
    prefix: []const u8,
    continuation: ?[]const u8,
) Error![]const u8 {
    var offset: usize = 0;
    if (continuation) |token| {
        try append_key_part(destination, &offset, "continuation-token=");
        try append_encoded(destination, &offset, token, false);
        try append_key_part(destination, &offset, "&");
    }
    try append_key_part(destination, &offset, "list-type=2&max-keys=");
    var number_buffer: [16]u8 = undefined;
    const keys_text = std.fmt.bufPrint(&number_buffer, "{d}", .{max_keys}) catch
        return error.StorageFailure;
    try append_key_part(destination, &offset, keys_text);
    // The level prefix scopes the listing; without it, higher-level keys
    // that sort after this level would leak into the result.
    try append_key_part(destination, &offset, "&prefix=");
    if (prefix.len > 0) {
        try append_encoded(destination, &offset, prefix, false);
        try append_encoded(destination, &offset, "/", false);
    }
    var level_name: [4]u8 = undefined;
    try append_encoded(
        destination,
        &offset,
        ltx.format_object_level_name(level, &level_name) catch
            return error.InvalidLevel,
        false,
    );
    try append_encoded(destination, &offset, "/", false);
    try append_key_part(destination, &offset, "&start-after=");
    if (prefix.len > 0) {
        // Query values percent-encode every reserved character, including
        // the slashes of the key prefix.
        try append_encoded(destination, &offset, prefix, false);
        try append_encoded(destination, &offset, "/", false);
    }
    try append_encoded(
        destination,
        &offset,
        ltx.format_object_level_name(level, &level_name) catch
            return error.InvalidLevel,
        false,
    );
    try append_encoded(destination, &offset, "/", false);
    var seek_name: [ltx.file_name_bytes]u8 = undefined;
    _ = ltx.format_file_name(seek, ltx.TXID.init(0), &seek_name);
    try append_encoded(destination, &offset, &seek_name, false);
    return destination[0..offset];
}

/// AWS canonical query strings give valueless parameters an empty value
/// (), and the same text is sent on the wire.
fn build_upload_query(destination: []u8, name: []const u8) Error![]const u8 {
    var offset: usize = 0;
    try append_key_part(destination, &offset, name);
    try append_key_part(destination, &offset, "=");
    return destination[0..offset];
}

fn build_upload_query_with_id(
    destination: []u8,
    upload_id: []const u8,
) Error![]const u8 {
    var offset: usize = 0;
    try append_key_part(destination, &offset, "uploadId=");
    try append_encoded(destination, &offset, upload_id, false);
    return destination[0..offset];
}

fn build_part_query(
    destination: []u8,
    part_number: u32,
    upload_id: []const u8,
) Error![]const u8 {
    var offset: usize = 0;
    try append_key_part(destination, &offset, "partNumber=");
    var number_buffer: [12]u8 = undefined;
    const text = std.fmt.bufPrint(&number_buffer, "{d}", .{part_number}) catch
        return error.StorageFailure;
    try append_key_part(destination, &offset, text);
    try append_key_part(destination, &offset, "&uploadId=");
    try append_encoded(destination, &offset, upload_id, false);
    return destination[0..offset];
}

fn append_multipart_xml(destination: []u8, offset: *usize, bytes: []const u8) Error!void {
    const end = std.math.add(usize, offset.*, bytes.len) catch
        return error.StorageFailure;
    if (end > destination.len) return error.StorageFailure;
    @memcpy(destination[offset.*..end], bytes);
    offset.* = end;
}

fn xml_text(xml: []const u8, opening: []const u8, closing: []const u8) ?[]const u8 {
    const opening_start = std.mem.indexOf(u8, xml, opening) orelse return null;
    const value_start = opening_start + opening.len;
    const value_end = std.mem.indexOfPos(u8, xml, value_start, closing) orelse
        return null;
    return xml[value_start..value_end];
}

fn decode_xml_text(encoded: []const u8, destination: []u8) Error![]const u8 {
    var source_index: usize = 0;
    var destination_index: usize = 0;
    while (source_index < encoded.len) {
        if (destination_index == destination.len) return error.StorageFailure;
        if (encoded[source_index] != '&') {
            destination[destination_index] = encoded[source_index];
            source_index += 1;
            destination_index += 1;
            continue;
        }
        const end = std.mem.indexOfScalarPos(u8, encoded, source_index + 1, ';') orelse
            return error.StorageFailure;
        const entity = encoded[source_index .. end + 1];
        destination[destination_index] = if (std.mem.eql(u8, entity, "&amp;"))
            '&'
        else if (std.mem.eql(u8, entity, "&lt;"))
            '<'
        else if (std.mem.eql(u8, entity, "&gt;"))
            '>'
        else if (std.mem.eql(u8, entity, "&quot;"))
            '"'
        else if (std.mem.eql(u8, entity, "&apos;"))
            '\''
        else
            return error.StorageFailure;
        destination_index += 1;
        source_index = end + 1;
    }
    return destination[0..destination_index];
}

/// AWS may return an XML error inside an HTTP 200 response while completing a
/// multipart upload. Publication is successful only when the bounded response
/// is a complete `CompleteMultipartUploadResult` document.
fn validate_complete_multipart_response(bytes: []const u8) Error!void {
    var document = std.mem.trim(u8, bytes, " \t\r\n");
    if (std.mem.startsWith(u8, document, "<?xml")) {
        const declaration_end = std.mem.indexOf(u8, document, "?>") orelse
            return error.StorageFailure;
        document = std.mem.trim(u8, document[declaration_end + 2 ..], " \t\r\n");
    }
    if (std.mem.indexOf(u8, document, "<Error") != null) {
        return error.StorageFailure;
    }
    const opening = "<CompleteMultipartUploadResult";
    if (!std.mem.startsWith(u8, document, opening)) return error.StorageFailure;
    if (document.len == opening.len) return error.StorageFailure;
    const opening_suffix = document[opening.len];
    if (opening_suffix != '>' and !std.ascii.isWhitespace(opening_suffix)) {
        return error.StorageFailure;
    }
    _ = std.mem.indexOfScalarPos(u8, document, opening.len, '>') orelse
        return error.StorageFailure;
    if (!std.mem.endsWith(
        u8,
        document,
        "</CompleteMultipartUploadResult>",
    )) return error.StorageFailure;
    const etag = xml_text(document, "<ETag>", "</ETag>") orelse
        return error.StorageFailure;
    if (etag.len == 0) return error.StorageFailure;
}

/// Reads a response to EOF into fixed caller-owned storage and probes one
/// extra byte when the storage fills exactly. This works for content-length,
/// chunked, and close-delimited HTTP bodies without allocating.
fn read_bounded_response_body(
    reader: *std.Io.Reader,
    destination: []u8,
) Error![]const u8 {
    const length = reader.readSliceShort(destination) catch
        return error.StorageFailure;
    if (length < destination.len) return destination[0..length];
    var extra: [1]u8 = undefined;
    const extra_length = reader.readSliceShort(&extra) catch
        return error.StorageFailure;
    if (extra_length != 0) return error.ObjectTooLarge;
    return destination;
}

fn append_key_part(destination: []u8, offset: *usize, bytes: []const u8) Error!void {
    const end = std.math.add(usize, offset.*, bytes.len) catch
        return error.PathTooLong;
    if (end > destination.len) return error.PathTooLong;
    @memcpy(destination[offset.*..end], bytes);
    offset.* = end;
}

/// Appends the strict AWS URI encoding of `source`: unreserved characters
/// pass through, everything else becomes uppercase `%XX`. Slash is preserved
/// only for path components.
fn append_encoded(
    destination: []u8,
    offset: *usize,
    source: []const u8,
    keep_slash: bool,
) Error!void {
    const unreserved = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~";
    for (source) |byte| {
        if (std.mem.indexOfScalar(u8, unreserved, byte) != null or
            (keep_slash and byte == '/'))
        {
            try append_key_part(destination, offset, &[1]u8{byte});
        } else {
            if (offset.* + 3 > destination.len) return error.PathTooLong;
            const hex = "0123456789ABCDEF";
            destination[offset.*] = '%';
            destination[offset.* + 1] = hex[byte >> 4];
            destination[offset.* + 2] = hex[byte & 0xf];
            offset.* += 3;
        }
    }
}

fn append_canonical(destination: []u8, offset: *usize, bytes: []const u8) Error!void {
    try append_key_part(destination, offset, bytes);
}

/// The signed-headers list is alphabetical; the optional conditional header
/// sorts between `host` and the `x-amz-*` headers.
fn signed_headers_text(
    has_metadata: bool,
    conditional_name: ?[]const u8,
    has_range: bool,
) []const u8 {
    if (conditional_name) |name| {
        if (std.mem.eql(u8, name, "if-match")) {
            if (has_range) {
                return if (has_metadata)
                    "host;if-match;range;x-amz-content-sha256;x-amz-date;x-amz-meta-litestream-timestamp"
                else
                    "host;if-match;range;x-amz-content-sha256;x-amz-date";
            }
            return if (has_metadata)
                "host;if-match;x-amz-content-sha256;x-amz-date;x-amz-meta-litestream-timestamp"
            else
                "host;if-match;x-amz-content-sha256;x-amz-date";
        }
        if (has_range) {
            return if (has_metadata)
                "host;if-none-match;range;x-amz-content-sha256;x-amz-date;x-amz-meta-litestream-timestamp"
            else
                "host;if-none-match;range;x-amz-content-sha256;x-amz-date";
        }
        return if (has_metadata)
            "host;if-none-match;x-amz-content-sha256;x-amz-date;x-amz-meta-litestream-timestamp"
        else
            "host;if-none-match;x-amz-content-sha256;x-amz-date";
    }
    if (has_range) {
        return if (has_metadata)
            "host;range;x-amz-content-sha256;x-amz-date;x-amz-meta-litestream-timestamp"
        else
            "host;range;x-amz-content-sha256;x-amz-date";
    }
    return if (has_metadata)
        "host;x-amz-content-sha256;x-amz-date;x-amz-meta-litestream-timestamp"
    else
        "host;x-amz-content-sha256;x-amz-date";
}

fn mark_bodyless_response_complete(
    request: *std.http.Client.Request,
    method: std.http.Method,
    status: std.http.Status,
) void {
    if (method != .HEAD and status.class() != .informational and
        status != .no_content and status != .not_modified)
    {
        return;
    }
    // Zig 0.16 otherwise treats an absent length as a close-delimited body
    // during Request.deinit(), which waits for an S3 keep-alive timeout.
    std.debug.assert(request.reader.state == .received_head);
    request.reader.state = .ready;
}

/// The retry decision: within budget, allowed for the method, and the
/// policy still returning a delay.
fn retry_delay(
    policy: RetryPolicy,
    attempt: u32,
    cause: RetryCause,
    method: std.http.Method,
    conditional: Conditional,
) ?u64 {
    if (attempt >= policy.max_attempts) return null;
    switch (conditional) {
        .none => {},
        .create_only, .match_etag => return null,
    }
    if (!method_retryable(method)) return null;
    return policy.next_delay_ms_fn(policy.context, attempt, cause);
}

fn post_send_failure(options: S3Client.RequestOptions) ConditionalWriteError {
    if (options.publication == .indeterminate_after_send) {
        return error.PublicationIndeterminate;
    }
    return switch (options.conditional) {
        .none => error.StorageFailure,
        .create_only, .match_etag => error.PublicationIndeterminate,
    };
}

fn conditional_status_failure(status: std.http.Status) ConditionalWriteError {
    if (@intFromEnum(status) >= 500 or status == .too_many_requests) {
        return error.PublicationIndeterminate;
    }
    return error.StorageFailure;
}

fn publication_status_failure(status: std.http.Status) Error {
    if (@intFromEnum(status) >= 500 or status == .too_many_requests) {
        return error.PublicationIndeterminate;
    }
    return error.StorageFailure;
}

fn abort_status_is_clean(status: std.http.Status) bool {
    return switch (status) {
        .ok, .no_content, .not_found => true,
        else => false,
    };
}

fn method_retryable(method: std.http.Method) bool {
    return switch (method) {
        .GET, .HEAD, .DELETE, .PUT => true,
        else => false,
    };
}

fn file_info_before(_: void, left: ltx.FileInfo, right: ltx.FileInfo) bool {
    if (left.min_txid.value != right.min_txid.value) {
        return left.min_txid.value < right.min_txid.value;
    }
    return left.max_txid.value < right.max_txid.value;
}

fn basename(key: []const u8) ?[]const u8 {
    const index = std.mem.lastIndexOfScalar(u8, key, '/') orelse return null;
    if (index + 1 >= key.len) return null;
    return key[index + 1 ..];
}

test "amz date formatting matches known calendar values" {
    // 1,785,101,704 Unix seconds is 2026-07-26T21:35:04Z.
    var out: [amz_date_bytes]u8 = undefined;
    try format_amz_date(1_785_101_704_000, &out);
    try std.testing.expectEqualStrings("20260726T213504Z", &out);
    try format_amz_date(0, &out);
    try std.testing.expectEqualStrings("19700101T000000Z", &out);
    try format_amz_date(86_400_000, &out);
    try std.testing.expectEqualStrings("19700102T000000Z", &out);
    // 1,739,888,000 seconds is 2025-02-18T14:13:20Z.
    try format_amz_date(1_739_888_000_000, &out);
    try std.testing.expectEqualStrings("20250218T141320Z", &out);
    try std.testing.expectError(
        error.InvalidTimestamp,
        format_amz_date(std.math.maxInt(u64), &out),
    );
}

test "Litestream timestamp formatting matches RFC3339Nano" {
    var out: [24]u8 = undefined;
    try std.testing.expectEqualStrings(
        "1970-01-01T00:00:00Z",
        try format_litestream_timestamp(0, &out),
    );
    try std.testing.expectEqualStrings(
        "1970-01-01T00:00:00.123Z",
        try format_litestream_timestamp(123, &out),
    );
    try std.testing.expectEqualStrings(
        "1970-01-01T00:00:00.12Z",
        try format_litestream_timestamp(120, &out),
    );
    try std.testing.expectEqualStrings(
        "1970-01-01T00:00:00.1Z",
        try format_litestream_timestamp(100, &out),
    );
    try std.testing.expectEqualStrings(
        "1969-12-31T23:59:59.999Z",
        try format_litestream_timestamp(-1, &out),
    );
    try std.testing.expectError(
        error.InvalidTimestamp,
        format_litestream_timestamp(std.math.maxInt(i64), &out),
    );
}

test "civil date conversion crosses leap years" {
    const epoch = civil_from_days(0);
    try std.testing.expectEqual(@as(i64, 1970), epoch.year);
    try std.testing.expectEqual(@as(u32, 1), epoch.month);
    try std.testing.expectEqual(@as(u32, 1), epoch.day);
    const new_year_1971 = civil_from_days(365);
    try std.testing.expectEqual(@as(i64, 1971), new_year_1971.year);
    try std.testing.expectEqual(@as(u32, 1), new_year_1971.month);
    try std.testing.expectEqual(@as(u32, 1), new_year_1971.day);
    const january_second = civil_from_days(366);
    try std.testing.expectEqual(@as(u32, 2), january_second.day);
}

test "list parsing binds every key to its exact stored size" {
    const FixedClock = struct {
        fn now_ms(_: *anyopaque) u64 {
            return 0;
        }
    };
    var clock_context: u8 = 0;
    var send_workspace: [1]u8 = undefined;
    var client = try S3Client.init(std.testing.allocator, std.testing.io, .{
        .host = "127.0.0.1",
        .port = 9000,
        .bucket = "test",
        .access_key = "key",
        .secret_key = "secret",
        .clock = .{ .context = &clock_context, .now_ms_fn = FixedClock.now_ms },
    }, &send_workspace);
    defer client.deinit();

    const page = try client.parse_list_page(
        \\<ListBucketResult><IsTruncated>true</IsTruncated>
        \\<Contents><Key>replica/0000/0000000000000001-0000000000000001.ltx</Key><Size>17</Size></Contents>
        \\<Contents><Key>replica/0000/0000000000000002-0000000000000002.ltx</Key><Size>4096</Size></Contents>
        \\<NextContinuationToken>next&amp;page</NextContinuationToken></ListBucketResult>
    );
    try std.testing.expectEqual(@as(usize, 2), page.keys.len);
    try std.testing.expectEqualSlices(u64, &.{ 17, 4096 }, page.sizes);
    try std.testing.expect(page.truncated);
    try std.testing.expectEqualStrings("next&page", page.next_token.?);
    try std.testing.expectError(
        error.StorageFailure,
        client.parse_list_page(
            "<ListBucketResult><Contents><Key>key</Key><Size>bad</Size></Contents></ListBucketResult>",
        ),
    );
    try std.testing.expectError(
        error.StorageFailure,
        client.parse_list_page("<ListBucketResult></ListBucketResult>"),
    );
}

test "listing page configuration stays within the fixed response budget" {
    const FixedClock = struct {
        fn now_ms(_: *anyopaque) u64 {
            return 0;
        }
    };
    var clock_context: u8 = 0;
    var send_workspace: [1]u8 = undefined;
    const base = Config{
        .host = "127.0.0.1",
        .port = 9000,
        .bucket = "test",
        .access_key = "key",
        .secret_key = "secret",
        .clock = .{ .context = &clock_context, .now_ms_fn = FixedClock.now_ms },
    };
    var zero = base;
    zero.max_keys_per_page = 0;
    try std.testing.expectError(
        error.InvalidConfiguration,
        S3Client.init(std.testing.allocator, std.testing.io, zero, &send_workspace),
    );
    var zero_pages = base;
    zero_pages.max_listing_pages = 0;
    try std.testing.expectError(
        error.InvalidConfiguration,
        S3Client.init(
            std.testing.allocator,
            std.testing.io,
            zero_pages,
            &send_workspace,
        ),
    );
    var excessive = base;
    excessive.max_keys_per_page = max_list_keys_per_page + 1;
    try std.testing.expectError(
        error.InvalidConfiguration,
        S3Client.init(std.testing.allocator, std.testing.io, excessive, &send_workspace),
    );
    var bounded = try S3Client.init(
        std.testing.allocator,
        std.testing.io,
        base,
        &send_workspace,
    );
    defer bounded.deinit();
}

test "multipart completion accepts only a success result" {
    try validate_complete_multipart_response(
        \\   <CompleteMultipartUploadResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
        \\     <Location>http://example.test/bucket/key</Location>
        \\     <Bucket>bucket</Bucket><Key>key</Key><ETag>"etag"</ETag>
        \\   </CompleteMultipartUploadResult>
    );
    try std.testing.expectError(
        error.StorageFailure,
        validate_complete_multipart_response(
            \\<Error><Code>InternalError</Code><Message>try again</Message></Error>
        ),
    );
    try std.testing.expectError(
        error.StorageFailure,
        validate_complete_multipart_response("<NotACompletionResult/>"),
    );
    try std.testing.expectError(
        error.StorageFailure,
        validate_complete_multipart_response(
            "<CompleteMultipartUploadResult></CompleteMultipartUploadResult>",
        ),
    );
}

test "response bodies are bounded without requiring a declared length" {
    var destination: [4]u8 = undefined;
    var short_reader = std.Io.Reader.fixed("abc");
    try std.testing.expectEqualStrings(
        "abc",
        try read_bounded_response_body(&short_reader, &destination),
    );

    var exact_reader = std.Io.Reader.fixed("abcd");
    try std.testing.expectEqualStrings(
        "abcd",
        try read_bounded_response_body(&exact_reader, &destination),
    );

    var long_reader = std.Io.Reader.fixed("abcde");
    try std.testing.expectError(
        error.ObjectTooLarge,
        read_bounded_response_body(&long_reader, &destination),
    );
}

test "empty payload hash is the standard constant" {
    var out: [sha256_hex_bytes]u8 = undefined;
    sha256_hex("", &out);
    try std.testing.expectEqualStrings(empty_payload_sha256, &out);
}

test "retry decisions respect budget, method, and policy callback" {
    const Probe = struct {
        calls: u32 = 0,
        sleep_calls: u32 = 0,
        last_delay_ms: u64 = 0,
        stop_after: u32 = std.math.maxInt(u32),
        fn next(context: *anyopaque, attempt: u32, cause: RetryCause) ?u64 {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.calls += 1;
            if (attempt >= self.stop_after) return null;
            return switch (cause) {
                .transport => 10,
                .status => |code| if (code == 429) 20 else null,
            };
        }

        fn sleep(context: *anyopaque, delay_ms: u64) Error!void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.sleep_calls += 1;
            self.last_delay_ms = delay_ms;
        }
    };
    var probe = Probe{};
    const policy = RetryPolicy{
        .context = &probe,
        .next_delay_ms_fn = Probe.next,
        .sleep_ms_fn = Probe.sleep,
        .max_attempts = 3,
    };

    // First failure within budget yields the callback's delay.
    try std.testing.expectEqual(
        @as(?u64, 10),
        retry_delay(policy, 1, .transport, .GET, .none),
    );
    // POST is never retried.
    try std.testing.expectEqual(
        @as(?u64, null),
        retry_delay(policy, 1, .transport, .POST, .none),
    );
    // A conditional PUT is not safely retryable after a lost response.
    try std.testing.expectEqual(
        @as(?u64, null),
        retry_delay(policy, 1, .transport, .PUT, .create_only),
    );
    // The last allowed attempt produces no further delay.
    try std.testing.expectEqual(
        @as(?u64, null),
        retry_delay(policy, 3, .transport, .GET, .none),
    );
    // A non-429 status stops through the callback.
    try std.testing.expectEqual(
        @as(?u64, null),
        retry_delay(policy, 1, .{ .status = 503 }, .PUT, .none),
    );
    try std.testing.expectEqual(
        @as(?u64, 20),
        retry_delay(policy, 1, .{ .status = 429 }, .PUT, .none),
    );
    try std.testing.expectEqual(@as(u32, 3), probe.calls);
    try policy.sleep_ms(20);
    try std.testing.expectEqual(@as(u32, 1), probe.sleep_calls);
    try std.testing.expectEqual(@as(u64, 20), probe.last_delay_ms);
}

test "conditional publication classifies post-send failure as indeterminate" {
    try std.testing.expectEqual(
        error.StorageFailure,
        post_send_failure(.{}),
    );
    try std.testing.expectEqual(
        error.PublicationIndeterminate,
        post_send_failure(.{ .conditional = .create_only }),
    );
    try std.testing.expectEqual(
        error.PublicationIndeterminate,
        post_send_failure(.{
            .conditional = .{ .match_etag = "\"generation\"" },
        }),
    );
    try std.testing.expectEqual(
        error.PublicationIndeterminate,
        post_send_failure(.{ .publication = .indeterminate_after_send }),
    );
}

test "publication status failures preserve uncertainty" {
    try std.testing.expectEqual(
        error.PublicationIndeterminate,
        publication_status_failure(.internal_server_error),
    );
    try std.testing.expectEqual(
        error.PublicationIndeterminate,
        publication_status_failure(.too_many_requests),
    );
    try std.testing.expectEqual(
        error.StorageFailure,
        publication_status_failure(.bad_request),
    );
}

test "multipart abort treats a missing upload as already clean" {
    try std.testing.expect(abort_status_is_clean(.ok));
    try std.testing.expect(abort_status_is_clean(.no_content));
    try std.testing.expect(abort_status_is_clean(.not_found));
    try std.testing.expect(!abort_status_is_clean(.internal_server_error));
}

test "signed header lists stay alphabetical across conditional variants" {
    try std.testing.expectEqualStrings(
        "host;x-amz-content-sha256;x-amz-date",
        signed_headers_text(false, null, false),
    );
    try std.testing.expectEqualStrings(
        "host;if-match;x-amz-content-sha256;x-amz-date",
        signed_headers_text(false, "if-match", false),
    );
    try std.testing.expectEqualStrings(
        "host;if-none-match;x-amz-content-sha256;x-amz-date",
        signed_headers_text(false, "if-none-match", false),
    );
    try std.testing.expectEqualStrings(
        "host;if-none-match;x-amz-content-sha256;x-amz-date;x-amz-meta-litestream-timestamp",
        signed_headers_text(true, "if-none-match", false),
    );
    try std.testing.expectEqualStrings(
        "host;range;x-amz-content-sha256;x-amz-date",
        signed_headers_text(false, null, true),
    );
    try std.testing.expectEqualStrings(
        "host;if-match;range;x-amz-content-sha256;x-amz-date",
        signed_headers_text(false, "if-match", true),
    );
}

test "content range parsing is strict and bounded" {
    try std.testing.expectEqual(
        S3Client.ContentRange{
            .start_bytes = 7,
            .end_bytes = 9,
            .total_bytes = 20,
        },
        try S3Client.parse_content_range("bytes 7-9/20"),
    );
    try std.testing.expectError(
        error.StorageFailure,
        S3Client.parse_content_range("bytes */20"),
    );
    try std.testing.expectError(
        error.StorageFailure,
        S3Client.parse_content_range("bytes 9-7/20"),
    );
    try std.testing.expectError(
        error.StorageFailure,
        S3Client.parse_content_range("bytes 7-20/20"),
    );
    try std.testing.expectError(
        error.StorageFailure,
        S3Client.parse_content_range("octets 7-9/20"),
    );
}

test "uri encoding preserves safe characters and escapes the rest" {
    var buffer: [16]u8 = undefined;
    var offset: usize = 0;
    try append_encoded(&buffer, &offset, "aZ0-._~", false);
    try append_encoded(&buffer, &offset, " ", false);
    try std.testing.expectEqualStrings("aZ0-._~%20", buffer[0..offset]);
    offset = 0;
    try append_encoded(&buffer, &offset, "a/b+c", true);
    try std.testing.expectEqualStrings("a/b%2Bc", buffer[0..offset]);
}
