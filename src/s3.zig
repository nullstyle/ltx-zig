//! S3-backed `ltx_object` client.
//!
//! Implements the object-client contract against S3-compatible stores using
//! path-style requests and AWS Signature Version 4, at the granularity this
//! milestone covers: single-request `PutObject` with the
//! `litestream-timestamp` metadata header, `GetObject`, per-object
//! `DeleteObject`, paginated `ListObjectsV2` with `start-after` seek, and
//! bucket creation. Keys follow the Litestream object-store layout
//! `{prefix}/{level:04x}/{min}-{max}.ltx`. Multipart upload, conditional
//! writes, TLS, and virtual-host addressing are not implemented yet.
//!
//! Object payloads, listings, and all signing scratch live in fixed
//! caller-owned buffers. The standard-library HTTP transport is the one
//! allocation point: it allocates pooled connections from the allocator
//! provided at initialization and nothing else allocates. The clock is
//! injected — no ambient time reads.
//!
//! The gate for this backend is `mise run s3-integration`, which starts a
//! local MinIO server and runs the backend-agnostic conformance suite
//! against it.

const std = @import("std");
const ltx = @import("ltx");
const object = @import("ltx_object");

pub const Error = object.Error;

/// Why a request is being considered for retry.
pub const RetryCause = union(enum) {
    /// The transport failed before a complete response arrived.
    transport,
    /// The store answered with a retryable HTTP status (5xx or 429).
    status: u16,
};

/// Caller-injected retry policy. Retries apply to transport failures and
/// to retryable statuses on idempotent methods only (GET, HEAD, DELETE,
/// PUT); POST requests such as multipart initiation are never retried,
/// because a retry could duplicate an upload. The library sleeps for the
/// returned delay through its Io between attempts; hosts that want jitter
/// or caps encode them in `next_delay_ms_fn`.
pub const RetryPolicy = struct {
    context: *anyopaque,
    next_delay_ms_fn: *const fn (context: *anyopaque, attempt: u32, cause: RetryCause) ?u64,
    /// Total attempts including the first.
    max_attempts: u32 = 3,
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
    /// Maximum keys requested per listing page. Pages also fit the internal
    /// XML workspace, bounding the response body size.
    max_keys_per_page: u32 = 512,
    /// Optional retry policy for transient transport failures and
    /// retryable statuses on idempotent requests.
    retry: ?RetryPolicy = null,
};

/// One in-flight multipart upload. A client tracks a single upload at a
/// time; part bytes stream through the send workspace one part at a time,
/// so an arbitrarily large object never needs to exist whole.
pub const MultipartState = struct {
    level: u8,
    identity: ltx.FileIdentity,
    upload_id_bytes: usize = 0,
    upload_id: [192]u8 = undefined,
    /// ETag per completed part, indexed by part number minus one.
    part_count: u32 = 0,
    etag_lengths: [max_multipart_parts]u8 = @splat(0),
    etags: [max_multipart_parts][64]u8 = @splat(@splat(0)),
};

pub const max_multipart_parts = 512;

const amz_date_bytes = 16;
const sha256_hex_bytes = 64;
const empty_payload_sha256 = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";

/// The S3 object client. Stateful and single-owner: keep it at a stable
/// address while the derived `Client` is in use. `send_workspace` is the
/// mutable staging region for outgoing object bytes, sized for the largest
/// written object.
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
    key_slices: [512][]const u8 = undefined,
    token_workspace: [256]u8 = undefined,
    etag_workspace: [128]u8 = undefined,
    multipart: ?MultipartState = null,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        config: Config,
        send_workspace: []u8,
    ) Error!S3Client {
        var self = S3Client{
            .allocator = allocator,
            .io = io,
            .config = config,
            .http = .{ .allocator = allocator, .io = io },
            .send_workspace = send_workspace,
        };
        if (config.use_tls) {
            if (config.ca_file) |path| {
                const now = std.Io.Clock.real.now(io);
                self.http.ca_bundle.addCertsFromFilePath(
                    allocator,
                    io,
                    now,
                    .cwd(),
                    path,
                ) catch return error.StorageFailure;
                // Pre-setting `now` stops the first TLS request from
                // replacing this bundle with a system rescan.
                self.http.now = now;
            }
        }
        return self;
    }

    pub fn deinit(self: *S3Client) void {
        self.http.deinit();
    }

    pub fn client(self: *S3Client) object.Client {
        return .{
            .context = self,
            .list_fn = list,
            .open_fn = open,
            .write_fn = write,
            .delete_fn = delete,
        };
    }

    /// Creates the bucket when absent; an already-owned bucket is success.
    pub fn ensure_bucket(self: *S3Client) Error!void {
        const outcome = try self.perform(.PUT, "/", "", null, null, null, .none);
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
        while (true) {
            const remaining = destination.len - count;
            const page_keys = @min(self.config.max_keys_per_page, remaining + 1);
            const query = try build_list_query(
                &self.query_workspace,
                page_keys,
                level,
                seek,
                self.config.prefix,
                continuation,
            );
            const outcome = try self.perform(.GET, "/", query, null, null, &self.xml_workspace, .none);
            if (outcome.status != .ok) return error.StorageFailure;
            const page = try self.parse_list_page(outcome.bytes);
            for (page.keys) |key| {
                const name = basename(key) orelse continue;
                const identity = ltx.parse_file_name(name) catch continue;
                if (identity.min_txid.value < seek.value) continue;
                if (count == destination.len) return error.ListingCapacityExceeded;
                destination[count] = .{
                    .level = level,
                    .min_txid = identity.min_txid,
                    .max_txid = identity.max_txid,
                };
                count += 1;
            }
            if (!page.truncated) break;
            continuation = page.next_token orelse return error.StorageFailure;
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
        const self: *S3Client = @ptrCast(@alignCast(context));
        const key = try self.key_path(level, identity);
        const outcome = try self.perform(.GET, key, "", null, null, destination, .none);
        if (outcome.status == .not_found) return error.ObjectNotFound;
        if (outcome.status != .ok) return error.StorageFailure;
        return outcome.bytes;
    }

    fn write(
        context: *anyopaque,
        level: u8,
        identity: ltx.FileIdentity,
        created_at_ms: i64,
        bytes: []const u8,
    ) Error!void {
        const self: *S3Client = @ptrCast(@alignCast(context));
        if (bytes.len > self.send_workspace.len) return error.ObjectTooLarge;
        const key = try self.key_path(level, identity);
        @memcpy(self.send_workspace[0..bytes.len], bytes);
        const outcome = try self.perform(
            .PUT,
            key,
            "",
            self.send_workspace[0..bytes.len],
            created_at_ms,
            null,
            .none,
        );
        if (outcome.status != .ok) return error.StorageFailure;
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
        if (self.multipart != null) return error.InvalidState;
        const key = try self.key_path(level, identity);
        const query = try build_upload_query(&self.query_workspace, "uploads");
        const outcome = try self.perform(
            .POST,
            key,
            query,
            null,
            created_at_ms,
            &self.xml_workspace,
            .none,
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
    }

    /// Uploads one part and records its ETag for completion. Part numbers
    /// start at one; consecutive calls may skip nothing.
    pub fn put_part(
        self: *S3Client,
        part_number: u32,
        bytes: []const u8,
    ) Error!void {
        var state = &(self.multipart orelse return error.InvalidState);
        if (part_number == 0 or part_number > max_multipart_parts) {
            return error.InvalidLevel;
        }
        if (part_number != state.part_count + 1) return error.InvalidState;
        if (bytes.len > self.send_workspace.len) return error.ObjectTooLarge;
        const key = try self.key_path(state.level, state.identity);
        const query = try build_part_query(
            &self.query_workspace,
            part_number,
            state.upload_id[0..state.upload_id_bytes],
        );
        @memcpy(self.send_workspace[0..bytes.len], bytes);
        const outcome = try self.perform(
            .PUT,
            key,
            query,
            self.send_workspace[0..bytes.len],
            null,
            null,
            .none,
        );
        if (outcome.status != .ok) return error.StorageFailure;
        const etag = outcome.etag orelse return error.StorageFailure;
        if (etag.len > 64) return error.StorageFailure;
        @memcpy(state.etags[state.part_count][0..etag.len], etag);
        state.etag_lengths[state.part_count] = @intCast(etag.len);
        state.part_count += 1;
    }

    /// Completes the in-flight multipart upload, publishing the object.
    pub fn complete_multipart(self: *S3Client) Error!void {
        const state = &(self.multipart orelse return error.InvalidState);
        if (state.part_count == 0) return error.InvalidState;
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
            body_buffer[0..body_offset],
            null,
            &self.xml_workspace,
            .none,
        );
        self.multipart = null;
        if (outcome.status != .ok) return error.StorageFailure;
    }

    /// Aborts the in-flight multipart upload, discarding its parts.
    pub fn abort_multipart(self: *S3Client) Error!void {
        const state = &(self.multipart orelse return error.InvalidState);
        const key = try self.key_path(state.level, state.identity);
        const query = try build_upload_query_with_id(
            &self.query_workspace,
            state.upload_id[0..state.upload_id_bytes],
        );
        const outcome = try self.perform(
            .DELETE,
            key,
            query,
            null,
            null,
            null,
            .none,
        );
        self.multipart = null;
        switch (outcome.status) {
            .ok, .no_content => {},
            else => return error.StorageFailure,
        }
    }

    /// Writes one object only when its key is absent, for host-side lease
    /// fencing: the first writer wins and later contenders receive
    /// `ObjectExists`. Uses `If-None-Match: *`, which the store must support.
    pub fn put_if_absent(
        self: *S3Client,
        level: u8,
        identity: ltx.FileIdentity,
        created_at_ms: i64,
        bytes: []const u8,
    ) Error!void {
        if (level > ltx.max_level) return error.InvalidLevel;
        if (identity.min_txid.value > identity.max_txid.value) {
            return error.InvalidIdentity;
        }
        if (bytes.len > self.send_workspace.len) return error.ObjectTooLarge;
        const key = try self.key_path(level, identity);
        @memcpy(self.send_workspace[0..bytes.len], bytes);
        const outcome = try self.perform(
            .PUT,
            key,
            "",
            self.send_workspace[0..bytes.len],
            created_at_ms,
            null,
            .create_only,
        );
        switch (outcome.status) {
            .ok, .created => {},
            .precondition_failed => return error.ObjectExists,
            else => return error.StorageFailure,
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
        const outcome = try self.perform(.HEAD, key, "", null, null, null, .none);
        if (outcome.status == .not_found) return error.ObjectNotFound;
        if (outcome.status != .ok) return error.StorageFailure;
        return outcome.etag orelse error.StorageFailure;
    }

    /// Writes one object only when its stored ETag equals `expected_etag`
    /// (as returned by `object_etag`, quotes included). This is the
    /// replace-if-generation primitive for lease renewal: a contender that
    /// renewed between the caller's read and write shifts the ETag and this
    /// call fails with `ETagMismatch`.
    pub fn put_if_match(
        self: *S3Client,
        level: u8,
        identity: ltx.FileIdentity,
        created_at_ms: i64,
        bytes: []const u8,
        expected_etag: []const u8,
    ) Error!void {
        if (level > ltx.max_level) return error.InvalidLevel;
        if (identity.min_txid.value > identity.max_txid.value) {
            return error.InvalidIdentity;
        }
        if (bytes.len > self.send_workspace.len) return error.ObjectTooLarge;
        const key = try self.key_path(level, identity);
        @memcpy(self.send_workspace[0..bytes.len], bytes);
        const outcome = try self.perform(
            .PUT,
            key,
            "",
            self.send_workspace[0..bytes.len],
            created_at_ms,
            null,
            .{ .match_etag = expected_etag },
        );
        switch (outcome.status) {
            .ok => {},
            .precondition_failed => return error.ETagMismatch,
            else => return error.StorageFailure,
        }
    }

    fn delete(
        context: *anyopaque,
        files: []const ltx.FileInfo,
    ) Error!void {
        const self: *S3Client = @ptrCast(@alignCast(context));
        for (files) |info| {
            const key = try self.key_path(
                info.level,
                .{ .min_txid = info.min_txid, .max_txid = info.max_txid },
            );
            const outcome = try self.perform(.DELETE, key, "", null, null, null, .none);
            switch (outcome.status) {
                // S3 answers a successful delete with 204 No Content.
                .ok, .no_content, .not_found => {},
                else => return error.StorageFailure,
            }
        }
    }

    const Outcome = struct {
        status: std.http.Status,
        /// Response bytes when a body destination was supplied and the
        /// status was OK; otherwise empty.
        bytes: []const u8 = &.{},
        /// The `ETag` response header when present, copied into client
        /// storage and valid until the next request.
        etag: ?[]const u8 = null,
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
        payload: ?[]u8,
        metadata_ms: ?i64,
        body_destination: ?[]u8,
        conditional: Conditional,
    ) Error!Outcome {
        const policy = self.config.retry orelse
            return self.perform_once(method, key, query, payload, metadata_ms, body_destination, conditional);
        var attempt: u32 = 1;
        while (true) : (attempt += 1) {
            const outcome = self.perform_once(
                method,
                key,
                query,
                payload,
                metadata_ms,
                body_destination,
                conditional,
            ) catch |err| {
                if (err != error.StorageFailure) return err;
                if (retry_delay(policy, attempt, .transport, method)) |delay| {
                    try self.sleep_retry(delay);
                    continue;
                }
                return err;
            };
            const retryable = @intFromEnum(outcome.status) >= 500 or
                outcome.status == .too_many_requests;
            if (retryable) {
                if (retry_delay(policy, attempt, .{
                    .status = @intFromEnum(outcome.status),
                }, method)) |delay| {
                    try self.sleep_retry(delay);
                    continue;
                }
            }
            return outcome;
        }
    }

    fn sleep_retry(self: *S3Client, delay_ms: u64) Error!void {
        const timeout = std.Io.Timeout{ .duration = .{
            .raw = std.Io.Duration.fromMilliseconds(@intCast(delay_ms)),
            .clock = std.Io.Clock.real,
        } };
        timeout.sleep(self.io) catch return error.StorageFailure;
    }

    /// Signs and performs exactly one request attempt.
    fn perform_once(
        self: *S3Client,
        method: std.http.Method,
        key: []const u8,
        query: []const u8,
        payload: ?[]u8,
        metadata_ms: ?i64,
        body_destination: ?[]u8,
        conditional: Conditional,
    ) Error!Outcome {
        const now_ms = self.config.clock.now_ms();
        var amz_date: [amz_date_bytes]u8 = undefined;
        format_amz_date(now_ms, &amz_date);
        var payload_hash: [sha256_hex_bytes]u8 = undefined;
        sha256_hex(payload orelse "", &payload_hash);

        var timestamp_buffer: [24]u8 = undefined;
        var timestamp_text: []const u8 = "";
        if (metadata_ms) |value| {
            timestamp_text = std.fmt.bufPrint(
                &timestamp_buffer,
                "{d}",
                .{value},
            ) catch return error.StorageFailure;
        }

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
            if (metadata_ms == null) null else timestamp_text,
            conditional,
            host_header,
        );

        var extra_headers: [4]std.http.Header = undefined;
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
        if (metadata_ms != null) {
            extra_headers[extra_count] = .{
                .name = "x-amz-meta-litestream-timestamp",
                .value = timestamp_text,
            };
            extra_count += 1;
        }
        switch (conditional) {
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

        if (payload) |body| {
            request.sendBodyComplete(body) catch return error.StorageFailure;
        } else if (method.requestHasBody()) {
            // PUT without a payload still carries a zero-length body.
            const empty = self.send_workspace[0..0];
            request.sendBodyComplete(empty) catch return error.StorageFailure;
        } else {
            request.sendBodiless() catch return error.StorageFailure;
        }
        var response = request.receiveHead(&self.redirect_buffer) catch
            return error.StorageFailure;
        const status = response.head.status;
        var etag: ?[]const u8 = null;
        var header_iterator = response.head.iterateHeaders();
        while (header_iterator.next()) |header| {
            if (std.ascii.eqlIgnoreCase(header.name, "etag")) {
                const length = @min(header.value.len, self.etag_workspace.len);
                @memcpy(self.etag_workspace[0..length], header.value[0..length]);
                etag = self.etag_workspace[0..length];
                break;
            }
        }
        if (status != .ok) return .{ .status = status };
        const destination = body_destination orelse
            return .{ .status = status, .etag = etag };
        const length_value = response.head.content_length orelse
            return error.StorageFailure;
        const length = std.math.cast(usize, length_value) orelse
            return error.ObjectTooLarge;
        if (length > destination.len) return error.ObjectTooLarge;
        const reader = response.reader(&self.transfer_buffer);
        reader.readSliceAll(destination[0..length]) catch
            return error.StorageFailure;
        return .{
            .status = status,
            .bytes = destination[0..length],
            .etag = etag,
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
        const signed_headers = signed_headers_text(timestamp_text != null, conditional_name);
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

    const ListPage = struct {
        keys: []const []const u8,
        truncated: bool,
        next_token: ?[]const u8,
    };

    /// Scans one ListObjectsV2 page for key entries, the truncation flag,
    /// and the continuation token (copied into `token_workspace` so it
    /// survives the next response reusing the XML workspace).
    fn parse_list_page(self: *S3Client, xml: []const u8) Error!ListPage {
        var count: usize = 0;
        var cursor: usize = 0;
        while (std.mem.indexOfPos(u8, xml, cursor, "<Key>")) |start| {
            const value_start = start + "<Key>".len;
            const value_end = std.mem.indexOfPos(u8, xml, value_start, "</Key>") orelse
                return error.StorageFailure;
            if (count == self.key_slices.len) return error.StorageFailure;
            self.key_slices[count] = xml[value_start..value_end];
            count += 1;
            cursor = value_end + "</Key>".len;
        }
        const truncated = std.mem.indexOf(u8, xml, "<IsTruncated>true<") != null;
        var next_token: ?[]const u8 = null;
        if (truncated) {
            const token_start = std.mem.indexOf(u8, xml, "<NextContinuationToken>") orelse
                return error.StorageFailure;
            const value_start = token_start + "<NextContinuationToken>".len;
            const value_end = std.mem.indexOfPos(u8, xml, value_start, "</NextContinuationToken>") orelse
                return error.StorageFailure;
            if (value_end - value_start > self.token_workspace.len) {
                return error.StorageFailure;
            }
            @memcpy(
                self.token_workspace[0 .. value_end - value_start],
                xml[value_start..value_end],
            );
            next_token = self.token_workspace[0 .. value_end - value_start];
        }
        return .{
            .keys = self.key_slices[0..count],
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

fn format_amz_date(now_ms: u64, out: *[amz_date_bytes]u8) void {
    const total_seconds = now_ms / 1000;
    const days: i64 = @intCast(total_seconds / 86_400);
    const day_seconds = total_seconds % 86_400;
    const civil = civil_from_days(days);
    _ = std.fmt.bufPrint(out, "{d:0>4}{d:0>2}{d:0>2}T{d:0>2}{d:0>2}{d:0>2}Z", .{
        @as(u32, @intCast(civil.year)),
        civil.month,
        civil.day,
        day_seconds / 3600,
        (day_seconds % 3600) / 60,
        day_seconds % 60,
    }) catch unreachable;
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
) []const u8 {
    if (conditional_name) |name| {
        if (std.mem.eql(u8, name, "if-match")) {
            return if (has_metadata)
                "host;if-match;x-amz-content-sha256;x-amz-date;x-amz-meta-litestream-timestamp"
            else
                "host;if-match;x-amz-content-sha256;x-amz-date";
        }
        return if (has_metadata)
            "host;if-none-match;x-amz-content-sha256;x-amz-date;x-amz-meta-litestream-timestamp"
        else
            "host;if-none-match;x-amz-content-sha256;x-amz-date";
    }
    return if (has_metadata)
        "host;x-amz-content-sha256;x-amz-date;x-amz-meta-litestream-timestamp"
    else
        "host;x-amz-content-sha256;x-amz-date";
}

/// The retry decision: within budget, allowed for the method, and the
/// policy still returning a delay.
fn retry_delay(
    policy: RetryPolicy,
    attempt: u32,
    cause: RetryCause,
    method: std.http.Method,
) ?u64 {
    if (attempt >= policy.max_attempts) return null;
    if (!method_retryable(method)) return null;
    return policy.next_delay_ms_fn(policy.context, attempt, cause);
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
    format_amz_date(1_785_101_704_000, &out);
    try std.testing.expectEqualStrings("20260726T213504Z", &out);
    format_amz_date(0, &out);
    try std.testing.expectEqualStrings("19700101T000000Z", &out);
    format_amz_date(86_400_000, &out);
    try std.testing.expectEqualStrings("19700102T000000Z", &out);
    // 1,739,888,000 seconds is 2025-02-18T14:13:20Z.
    format_amz_date(1_739_888_000_000, &out);
    try std.testing.expectEqualStrings("20250218T141320Z", &out);
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

test "empty payload hash is the standard constant" {
    var out: [sha256_hex_bytes]u8 = undefined;
    sha256_hex("", &out);
    try std.testing.expectEqualStrings(empty_payload_sha256, &out);
}

test "retry decisions respect budget, method, and policy callback" {
    const Probe = struct {
        calls: u32 = 0,
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
    };
    var probe = Probe{};
    const policy = RetryPolicy{
        .context = &probe,
        .next_delay_ms_fn = Probe.next,
        .max_attempts = 3,
    };

    // First failure within budget yields the callback's delay.
    try std.testing.expectEqual(@as(?u64, 10), retry_delay(policy, 1, .transport, .GET));
    // POST is never retried.
    try std.testing.expectEqual(@as(?u64, null), retry_delay(policy, 1, .transport, .POST));
    // The last allowed attempt produces no further delay.
    try std.testing.expectEqual(@as(?u64, null), retry_delay(policy, 3, .transport, .GET));
    // A non-429 status stops through the callback.
    try std.testing.expectEqual(@as(?u64, null), retry_delay(policy, 1, .{ .status = 503 }, .PUT));
    try std.testing.expectEqual(@as(?u64, 20), retry_delay(policy, 1, .{ .status = 429 }, .PUT));
    try std.testing.expectEqual(@as(u32, 3), probe.calls);
}

test "signed header lists stay alphabetical across conditional variants" {
    try std.testing.expectEqualStrings(
        "host;x-amz-content-sha256;x-amz-date",
        signed_headers_text(false, null),
    );
    try std.testing.expectEqualStrings(
        "host;if-match;x-amz-content-sha256;x-amz-date",
        signed_headers_text(false, "if-match"),
    );
    try std.testing.expectEqualStrings(
        "host;if-none-match;x-amz-content-sha256;x-amz-date",
        signed_headers_text(false, "if-none-match"),
    );
    try std.testing.expectEqualStrings(
        "host;if-none-match;x-amz-content-sha256;x-amz-date;x-amz-meta-litestream-timestamp",
        signed_headers_text(true, "if-none-match"),
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
