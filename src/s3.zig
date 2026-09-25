//! S3-backed `ltx_object` client.
//!
//! Implements the object-client contract against S3-compatible stores using
//! path-style requests and AWS Signature Version 4, at the granularity this
//! milestone covers: single-request `PutObject` with the
//! `litestream-timestamp` metadata header, ETag-bound ranged `GetObject`,
//! per-object
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
//! before it advances a durable position or discards source objects. A host
//! that alone writes its LTX keys can let the client do that for write
//! sessions (`Config.single_writer_publication`): a publication is sent again
//! with the same bytes, and one whose outcome is still not known blocks every
//! write and delete until `settle` resolves it.
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

/// A listing page that says it is truncated but carries no continuation
/// token ends the walk; the level is listed again from its start at most
/// this many times before the listing fails.
pub const max_listing_restarts: u32 = 2;

/// Why a request is being considered for retry.
pub const RetryCause = union(enum) {
    /// The transport failed before a complete response arrived.
    transport,
    /// The store answered a status that may pass (`is_transient_status`).
    status: u16,
};

/// Caller-injected retry policy. A connect that failed sent nothing, so
/// every request is retried after one. After sending, transport failures
/// and statuses that may pass (`is_transient_status`) are retried for
/// GET, HEAD, DELETE and unconditional PUT; a ranged GET constrained by
/// `If-Match` keeps its generation. A conditional PUT is retried only
/// after a transient 4xx, where the store stored nothing; POST and
/// transactional publication never once sent: a lost answer or a 5xx may
/// hide a write, and the request ends `PublicationIndeterminate`, whatever
/// a later attempt found. Under `Config.single_writer_publication` a write
/// session's publication is sent again with the same bytes (and ends well
/// once one is answered 2xx), and a multipart initiation is sent again.
/// Delay selection and sleeping are both injected so
/// the module never reads an ambient clock; hosts encode jitter, caps,
/// cancellation, and the actual wait in these callbacks.
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

/// How far one request attempt got.
pub const Stage = enum {
    /// Taking a pooled connection or opening one: nothing was sent.
    connect,
    /// Sending the request's head and body.
    send,
    /// Waiting for the answer's head.
    receive_head,
    /// Taking the answer's `ETag` and `Content-Range` headers.
    headers,
    /// An answer arrived, whatever its status; its body, when read, was
    /// read whole.
    status,
    /// Reading the answer's body.
    read_body,
    /// The answer arrived whole but did not parse (`S3Client.
    /// last_parse_failure` says how). No attempt ends here: the parse
    /// comes after the request, so only a host that reports the failure
    /// names this stage.
    parse,
};

/// One request attempt as it begins. Slices are valid only during the call.
pub const Attempt = struct {
    method: std.http.Method,
    /// The object path, percent-encoded and starting with `/`; `/` for a
    /// bucket or a listing.
    key: []const u8,
    /// The query, percent-encoded; empty when there is none.
    query: []const u8,
    /// From 1.
    attempt: u32,
    /// The pool had an open connection, which the attempt takes.
    reused: bool,
    /// Since this client's previous attempt ended, on `Config.steady_clock`;
    /// 0 for its first.
    idle_ms: u64,
};

/// One request attempt as it ends. Slices are valid only during the call.
pub const AttemptEnd = struct {
    attempt: *const Attempt,
    /// The stage that failed, or `status` once an answer arrived.
    stage: Stage,
    /// The answer's status; 0 when none arrived.
    status: u16,
    /// The `<Code>` of an error answer's body; empty when none was read.
    s3_code: []const u8,
    /// The error the attempt failed with; null when an answer arrived.
    failure: ?ConditionalWriteError,
    /// The transport's own error under `failure` (a refused connect, a
    /// connection closed before the answer), when there is one.
    cause: ?anyerror,
    /// Since the request's first attempt began, on `Config.steady_clock`.
    elapsed_ms: u64,
    /// The client sends the request again after the policy's pause.
    will_retry: bool,
};

/// Caller-injected view of every request attempt: a host logs, counts or
/// watches requests with it. `begin_fn` runs before an attempt connects,
/// `stage_fn` (optional) as it moves on to each later stage, and `end_fn`
/// before the retry pause, if any. The callbacks run on the thread that
/// makes the request, and must not call the client.
pub const Observer = struct {
    context: *anyopaque,
    begin_fn: *const fn (context: *anyopaque, attempt: *const Attempt) void,
    stage_fn: ?*const fn (context: *anyopaque, stage: Stage) void = null,
    end_fn: *const fn (context: *anyopaque, end: *const AttemptEnd) void,
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

/// Injected clock returning milliseconds: Unix time for `Config.clock`,
/// any origin for `Config.steady_clock`.
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
    /// A clock that never steps back, for the time between attempts: how
    /// long the client sat idle (`max_idle_reuse_ms`, `Attempt.idle_ms`)
    /// and how long a request's attempts took (`AttemptEnd.elapsed_ms`).
    /// Any origin; `clock` when null. The wall clock can step back (NTP, an
    /// operator), and on it an idle connection looks fresher than it is.
    steady_clock: ?Clock = null,
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
    /// Close the pooled connections before an attempt when the client's
    /// previous attempt ended longer ago than this, on `steady_clock`: a
    /// store or a proxy closes an idle connection (MinIO after 30 s)
    /// without the client knowing, and a request sent into it fails. 0
    /// keeps them.
    max_idle_reuse_ms: u64 = 0,
    /// Optional observer of every request attempt.
    observer: ?Observer = null,
    /// This client alone writes the keys its write sessions publish, so a
    /// publication may be sent again with the same bytes: a write
    /// session's PUT and its multipart completion are retried under the
    /// policy after a lost answer or a transient status, and a multipart
    /// initiation is retried (a lost one leaves an upload nothing
    /// completes). A publication whose outcome is still not known, and an
    /// upload whose abort failed, leave the client unsettled
    /// (`unsettled_publication`): every write and delete then returns
    /// `PublicationUnsettled`, so no other bytes and no overlapping object
    /// are written while an earlier attempt could still land, until
    /// `settle` resolves it. Reads and listings go on.
    single_writer_publication: bool = false,
};

/// A publication whose outcome is not known, or an upload that may still be
/// open, under `Config.single_writer_publication`.
pub const Unsettled = union(enum) {
    /// A write session's single PUT that was sent and got no definite
    /// answer. Its bytes stay in the send workspace for `settle`.
    single_put: struct { level: u8, identity: ltx.FileIdentity, created_at_ms: i64, length_bytes: usize },
    /// A multipart upload whose abort failed, or whose completion was sent
    /// and may have landed (`complete_sent`). The upload stays in
    /// `S3Client.multipart` for `settle`.
    multipart: struct { level: u8, identity: ltx.FileIdentity, complete_sent: bool },
};

/// How `settle` resolved an unsettled publication.
pub const Settlement = enum {
    /// Nothing was unsettled.
    none,
    /// The key holds exactly the publication's bytes; an earlier attempt
    /// that lands late writes them again.
    landed,
    /// The upload was aborted and nothing of it is at the key; nothing of
    /// it can land any more.
    cancelled,
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
    /// A completion was sent and may have landed.
    complete_sent: bool = false,
    /// An abort was answered: no completion can land any more.
    aborted: bool = false,
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

/// Room for the percent-encoded path of one object: S3 keys stop at 1,024
/// bytes, and each byte encodes to at most three.
const path_workspace_bytes = 4096;
/// Room for one listing query: a continuation token (an opaque string the
/// store makes from the last key, MinIO's base64 of it with a suffix) and
/// the prefix twice, all percent-encoded.
const query_workspace_bytes = 8192;
/// Room for a decoded continuation token built from a 1,024-byte key.
const token_workspace_bytes = 2048;
/// S3 error codes are short CamelCase words (`SlowDown`,
/// `XMinioServerNotInitialized`); a longer one is not kept.
const max_s3_code_bytes = 64;
/// An error answer's body is read for its code only up to this length,
/// and not at all when it declares more than `max_error_body_bytes`.
const error_body_read_bytes = 1024;
const max_error_body_bytes = 4096;

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
    path_workspace: [path_workspace_bytes]u8 = undefined,
    query_workspace: [query_workspace_bytes]u8 = undefined,
    /// The canonical request holds the path and the query.
    canonical_workspace: [16 * 1024]u8 = undefined,
    string_to_sign_workspace: [512]u8 = undefined,
    authorization_workspace: [512]u8 = undefined,
    redirect_buffer: [1024]u8 = undefined,
    transfer_buffer: [16 * 1024]u8 = undefined,
    xml_workspace: [64 * 1024]u8 = undefined,
    key_slices: [max_list_keys_per_page][]const u8 = undefined,
    size_values: [max_list_keys_per_page]u64 = undefined,
    token_workspace: [token_workspace_bytes]u8 = undefined,
    etag_workspace: [object.max_read_generation_bytes]u8 = undefined,
    /// The `<Code>` of the last error answer, valid until the next request.
    s3_code_workspace: [max_s3_code_bytes]u8 = undefined,
    multipart: ?MultipartState = null,
    multipart_owner: ?MultipartOwner = null,
    write_session: ?StreamingWriteState = null,
    /// When this client's last request attempt ended, on
    /// `Config.steady_clock`; null before its first.
    last_attempt_end_ms: ?u64 = null,
    /// Why the last request's answer, read whole, did not parse (a static
    /// string); empty when it did, or the request failed otherwise. Reset
    /// by every request.
    last_parse_failure: []const u8 = "",
    /// Under `Config.single_writer_publication`: a publication `settle`
    /// must resolve before anything else is written.
    unsettled: ?Unsettled = null,

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

    /// Builds the object path for one level and identity: the key with its
    /// prefix URI-encoded (slashes kept), as the request line and the
    /// canonical request both carry it. The level and file names need no
    /// encoding.
    fn key_path(
        self: *S3Client,
        level: u8,
        identity: ltx.FileIdentity,
    ) Error![]const u8 {
        if (level > ltx.max_level) return error.InvalidLevel;
        var offset: usize = 0;
        try append_key_part(&self.path_workspace, &offset, "/");
        try append_encoded(&self.path_workspace, &offset, self.config.prefix, true);
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
        var restarts: u32 = 0;
        while (restarts <= max_listing_restarts) : (restarts += 1) {
            if (try self.list_walk(level, seek, destination)) |listed| {
                std.sort.pdq(ltx.FileInfo, listed, {}, file_info_before);
                return listed;
            }
        }
        self.last_parse_failure = "a truncated listing page without a continuation token";
        return error.StorageFailure;
    }

    /// One walk of a level's pages from the start. Null when a page said it
    /// was truncated but carried no continuation token: the store lost its
    /// place, and only a new walk can find the rest.
    fn list_walk(
        self: *S3Client,
        level: u8,
        seek: ltx.TXID,
        destination: []ltx.FileInfo,
    ) Error!?[]ltx.FileInfo {
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
            const page = self.parse_list_page(outcome.bytes) catch |err| {
                if (self.last_parse_failure.len == 0) {
                    self.last_parse_failure = "a listing page that does not parse";
                }
                return err;
            };
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
            continuation = page.next_token orelse return null;
        } else {
            return error.ListingPageLimitExceeded;
        }
        return destination[0..count];
    }

    fn read_range(
        context: *anyopaque,
        info: ltx.FileInfo,
        expected_generation: ?object.ReadGeneration,
        offset_bytes: u64,
        destination: []u8,
    ) Error!object.ReadGeneration {
        const self: *S3Client = @ptrCast(@alignCast(context));
        std.debug.assert(destination.len > 0);
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
            .conditional = if (expected_generation) |generation|
                .{ .match_etag = generation.value() }
            else
                .none,
            .byte_range = .{
                .start_bytes = offset_bytes,
                .end_bytes = end_bytes,
            },
        });
        if (outcome.status == .not_found) return error.ObjectNotFound;
        if (outcome.status == .precondition_failed) return error.ObjectChanged;
        if (outcome.status == .range_not_satisfiable) return error.ObjectChanged;
        if (outcome.status != .partial_content) return error.StorageFailure;
        const content_range = outcome.content_range orelse {
            self.last_parse_failure = "a ranged answer without a Content-Range";
            return error.StorageFailure;
        };
        if (content_range.total_bytes != info.size_bytes) {
            return error.ObjectChanged;
        }
        if (content_range.start_bytes != offset_bytes or
            content_range.end_bytes != end_bytes)
        {
            self.last_parse_failure = "a ranged answer for another range";
            return error.StorageFailure;
        }
        const etag = outcome.etag orelse {
            self.last_parse_failure = "a ranged answer without an ETag";
            return error.StorageFailure;
        };
        return object.ReadGeneration.init(etag);
    }

    fn write(
        context: *anyopaque,
        level: u8,
        identity: ltx.FileIdentity,
        created_at_ms: i64,
        bytes: []const u8,
    ) Error!void {
        const self: *S3Client = @ptrCast(@alignCast(context));
        try self.check_settled();
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
        try self.check_settled();
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

    /// A write session's object in one PUT. Under
    /// `single_writer_publication` it is sent again with the same bytes, and
    /// one that stays indeterminate leaves the client unsettled with its
    /// bytes kept in the send workspace.
    fn finish_single_put(
        self: *S3Client,
        state: *const StreamingWriteState,
    ) Error!void {
        const key = try self.key_path(state.level, state.identity);
        const settles = self.config.single_writer_publication;
        const outcome = self.perform(
            .PUT,
            key,
            "",
            .{
                .payload = self.send_workspace[0..state.buffered_bytes],
                .metadata_ms = state.created_at_ms,
                .publication = .indeterminate_after_send,
                .replay = if (settles) .same_bytes else .none,
            },
        ) catch |err| {
            if (settles and err == error.PublicationIndeterminate) {
                self.unsettled = .{ .single_put = .{
                    .level = state.level,
                    .identity = state.identity,
                    .created_at_ms = state.created_at_ms,
                    .length_bytes = state.buffered_bytes,
                } };
            }
            return err;
        };
        // A 5xx or a lost answer is `PublicationIndeterminate` from
        // `perform`; any other status is the store's refusal.
        if (outcome.status.class() != .success) return error.StorageFailure;
    }

    fn abort_write_session(context: *anyopaque) void {
        const self: *S3Client = @ptrCast(@alignCast(context));
        if (self.write_session == null) return;
        if (self.multipart_owner == .write_session) {
            // Under `single_writer_publication` a failed abort leaves the
            // client unsettled; otherwise the upload is kept for an
            // explicit cleanup retry.
            self.abort_multipart_owned(.write_session) catch {};
        }
        self.write_session = null;
    }

    fn has_active_write(self: *const S3Client) bool {
        return self.write_session != null or self.multipart != null;
    }

    /// Every write and delete first: nothing is written while a
    /// publication is unsettled. Before `has_active_write`, so an upload
    /// kept for its settlement reads as unsettled, not as a caller's
    /// misuse.
    fn check_settled(self: *const S3Client) Error!void {
        if (self.unsettled != null) return error.PublicationUnsettled;
    }

    /// The publication `settle` must resolve before anything else is
    /// written; null when there is none.
    pub fn unsettled_publication(self: *const S3Client) ?Unsettled {
        return self.unsettled;
    }

    /// Resolves an unsettled publication (`Config.single_writer_publication`)
    /// with requests retried under the policy:
    /// - a single PUT is sent again with the same bytes until one is
    ///   answered 2xx (`landed`);
    /// - an upload whose completion was sent gets the completion again
    ///   (`landed` when it lands); otherwise the upload is aborted (204 and
    ///   404 are clean), and when a completion was sent a HEAD of the key
    ///   says whether it landed first (`landed`) or not (`cancelled`);
    /// - an upload no completion was sent for is aborted (`cancelled`).
    /// A failure returns its error and leaves the publication unsettled
    /// (`PublicationIndeterminate` when a resend may have landed); calling
    /// again continues. Settled, the client writes again.
    pub fn settle(self: *S3Client) ConditionalWriteError!Settlement {
        const unsettled = self.unsettled orelse return .none;
        const settlement: Settlement = switch (unsettled) {
            .single_put => |put| try self.resend_single_put(put.level, put.identity, put.created_at_ms, put.length_bytes),
            .multipart => try self.settle_upload(),
        };
        self.unsettled = null;
        return settlement;
    }

    fn resend_single_put(
        self: *S3Client,
        level: u8,
        identity: ltx.FileIdentity,
        created_at_ms: i64,
        length_bytes: usize,
    ) ConditionalWriteError!Settlement {
        const key = try self.key_path(level, identity);
        const outcome = try self.perform(.PUT, key, "", .{
            .payload = self.send_workspace[0..length_bytes],
            .metadata_ms = created_at_ms,
            .publication = .indeterminate_after_send,
            .replay = .same_bytes,
        });
        // A refusal of this resend says nothing of the attempt before it.
        if (outcome.status.class() != .success) return error.StorageFailure;
        return .landed;
    }

    /// `settle` for an upload kept in `multipart`.
    fn settle_upload(self: *S3Client) ConditionalWriteError!Settlement {
        const state = &self.multipart.?;
        const owner = self.multipart_owner.?;
        if (state.complete_sent and !state.aborted) {
            if (self.send_completion(state)) {
                self.end_multipart();
                return .landed;
            } else |_| {}
        }
        try self.abort_multipart_owned(owner);
        if (self.multipart == null) return .cancelled;
        // A completion was sent: it landed before the abort, or it never
        // will.
        const landed = try self.upload_landed(state);
        self.end_multipart();
        return if (landed) .landed else .cancelled;
    }

    fn end_multipart(self: *S3Client) void {
        self.multipart = null;
        self.multipart_owner = null;
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
        try self.check_settled();
        if (self.write_session != null) return error.InvalidState;
        return self.begin_multipart_owned(
            .manual,
            level,
            identity,
            created_at_ms,
        );
    }

    /// Under `single_writer_publication` a lost answer is sent again: an
    /// earlier attempt that the store took leaves an upload whose id never
    /// came back, which nothing completes (store-side lifecycle cleanup
    /// removes it).
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
                .replay = if (self.config.single_writer_publication) .orphan_only else .none,
            },
        );
        if (outcome.status != .ok) return error.StorageFailure;
        var state = MultipartState{ .level = level, .identity = identity };
        const upload_id = xml_text(outcome.bytes, "<UploadId>", "</UploadId>") orelse {
            self.last_parse_failure = "an initiation answer without an UploadId";
            return error.StorageFailure;
        };
        if (upload_id.len > state.upload_id.len) {
            self.last_parse_failure = "an UploadId over 192 bytes";
            return error.StorageFailure;
        }
        @memcpy(state.upload_id[0..upload_id.len], upload_id);
        state.upload_id_bytes = upload_id.len;
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
        try self.check_settled();
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
    /// before retrying or deleting source state. Under
    /// `single_writer_publication` the completion is sent again with the same
    /// body instead, and a HEAD of the key decides one that stays
    /// indeterminate: this upload's object there is success; otherwise the
    /// upload stays unsettled for `settle`.
    pub fn complete_multipart(self: *S3Client) Error!void {
        try self.check_settled();
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
        self.send_completion(state) catch |err| {
            if (err == error.PublicationIndeterminate and self.config.single_writer_publication) {
                self.unsettle_upload(state);
            }
            return err;
        };
        self.end_multipart();
    }

    /// Keep the upload for `settle`: its abort failed, or its completion
    /// may have landed.
    fn unsettle_upload(self: *S3Client, state: *const MultipartState) void {
        self.unsettled = .{ .multipart = .{
            .level = state.level,
            .identity = state.identity,
            .complete_sent = state.complete_sent,
        } };
    }

    /// Sends `state`'s completion. Under `single_writer_publication` it is
    /// sent again with the same body while the policy allows; once an
    /// attempt may have landed, or the upload is gone (404) after an earlier
    /// completion was sent, a HEAD of the key decides: this upload's object
    /// there is success, anything else `PublicationIndeterminate`. A store
    /// answers a completion of an upload it already completed or aborted
    /// with 404 `NoSuchUpload`.
    fn send_completion(self: *S3Client, state: *MultipartState) ConditionalWriteError!void {
        const settles = self.config.single_writer_publication;
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
        const result = self.perform(
            .POST,
            key,
            query,
            .{
                .payload = body_buffer[0..body_offset],
                .body_destination = &self.xml_workspace,
                .publication = .indeterminate_after_send,
                .replay = if (settles) .same_bytes else .none,
            },
        );
        const outcome = result catch |err| {
            if (!settles or err != error.PublicationIndeterminate) return err;
            state.complete_sent = true;
            return self.head_decides(state);
        };
        if (outcome.status != .ok) {
            // The store refused this request, which stored nothing; an
            // earlier completion may have landed.
            if (settles and state.complete_sent and outcome.status == .not_found) return self.head_decides(state);
            return error.StorageFailure;
        }
        validate_complete_multipart_response(outcome.bytes) catch {
            self.last_parse_failure = "a completion answer that is not a CompleteMultipartUploadResult";
            if (!settles) return error.PublicationIndeterminate;
            state.complete_sent = true;
            return self.head_decides(state);
        };
    }

    /// A completion that may have landed: success when a HEAD finds this
    /// upload's object at the key, `PublicationIndeterminate` otherwise
    /// (the HEAD failed, or the key holds something else or nothing).
    fn head_decides(self: *S3Client, state: *const MultipartState) ConditionalWriteError!void {
        const landed = self.upload_landed(state) catch false;
        if (!landed) return error.PublicationIndeterminate;
    }

    /// Whether the key holds this upload's completed object, by a HEAD: its
    /// ETag is the one a store computes for these parts (the MD5 of the
    /// parts' binary MD5s, then `-` and the part count) and its length the
    /// parts' sum. A part ETag that is not an MD5 (a store that encrypts
    /// with KMS) leaves only the count suffix and the length to compare.
    fn upload_landed(self: *S3Client, state: *const MultipartState) ConditionalWriteError!bool {
        const key = try self.key_path(state.level, state.identity);
        const outcome = try self.perform(.HEAD, key, "", .{});
        if (outcome.status == .not_found) return false;
        if (outcome.status != .ok) return error.StorageFailure;
        const etag = outcome.etag orelse return false;
        var total_bytes: u64 = 0;
        for (state.part_sizes[0..state.part_count]) |size| total_bytes += size;
        if (outcome.content_length != total_bytes) return false;
        var expected: [upload_etag_bytes]u8 = undefined;
        if (upload_etag(state, &expected)) |computed| return std.ascii.eqlIgnoreCase(etag, computed);
        var suffix: [16]u8 = undefined;
        return std.mem.endsWith(u8, etag, std.fmt.bufPrint(&suffix, "-{d}\"", .{state.part_count}) catch unreachable);
    }

    /// Aborts the in-flight multipart upload, discarding its parts. A failed
    /// cleanup retains the upload identity so the caller or `deinit` can retry;
    /// all new writes remain blocked until cleanup succeeds. Under
    /// `single_writer_publication` a failed abort leaves the client
    /// unsettled instead, and only `settle` retries it.
    pub fn abort_multipart(self: *S3Client) Error!void {
        try self.check_settled();
        if (self.write_session != null) return error.InvalidState;
        const owner = self.multipart_owner orelse return error.InvalidState;
        return self.abort_multipart_owned(owner);
    }

    /// Under `single_writer_publication` a failed abort, and an upload whose
    /// completion was sent (until a HEAD says whether it landed), stay
    /// unsettled with the upload kept.
    fn abort_multipart_owned(
        self: *S3Client,
        owner: MultipartOwner,
    ) Error!void {
        const state = &(self.multipart orelse return error.InvalidState);
        if (self.multipart_owner != owner) return error.InvalidState;
        const settles = self.config.single_writer_publication;
        const key = try self.key_path(state.level, state.identity);
        const query = try build_upload_query_with_id(
            &self.query_workspace,
            state.upload_id[0..state.upload_id_bytes],
        );
        const outcome = self.perform(
            .DELETE,
            key,
            query,
            .{},
        ) catch |err| {
            if (settles) self.unsettle_upload(state);
            return err;
        };
        if (!abort_status_is_clean(outcome.status)) {
            if (settles) self.unsettle_upload(state);
            return error.StorageFailure;
        }
        if (settles and state.complete_sent) {
            state.aborted = true;
            self.unsettle_upload(state);
            return;
        }
        self.end_multipart();
    }

    /// Writes one object only when its key is absent, for host-side lease
    /// fencing: the first writer wins and later contenders receive
    /// `ObjectExists`. Uses `If-None-Match: *`, which the store must support.
    /// A failure after delivery begins without a definite answer (a lost
    /// answer, a 5xx) returns `PublicationIndeterminate` and is never
    /// retried automatically; reconcile the stored generation. A refused
    /// connect and a transient 4xx (the store stored nothing) are retried
    /// under the policy. To reconcile, read the object back: bytes equal
    /// to these mean the write landed; anything else is another writer's.
    pub fn put_if_absent(
        self: *S3Client,
        level: u8,
        identity: ltx.FileIdentity,
        created_at_ms: i64,
        bytes: []const u8,
    ) ConditionalWriteError!void {
        try self.check_settled();
        if (self.has_active_write()) return error.InvalidState;
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
            .{
                .payload = self.send_workspace[0..bytes.len],
                .metadata_ms = created_at_ms,
                .conditional = .create_only,
                .publication = .indeterminate_after_send,
            },
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
        const outcome = try self.perform(.HEAD, key, "", .{});
        if (outcome.status == .not_found) return error.ObjectNotFound;
        if (outcome.status != .ok) return error.StorageFailure;
        return outcome.etag orelse {
            self.last_parse_failure = "an answer without an ETag";
            return error.StorageFailure;
        };
    }

    /// Writes one object only when its stored ETag equals `expected_etag`
    /// (as returned by `object_etag`, quotes included). This is the
    /// replace-if-generation primitive for lease renewal: a contender that
    /// renewed between the caller's read and write shifts the ETag and this
    /// call fails with `ETagMismatch`. A failure after delivery begins
    /// without a definite answer returns `PublicationIndeterminate` and is
    /// never retried automatically; reconcile the stored generation before
    /// renewal continues. It is retried as `put_if_absent` is. To
    /// reconcile, read the object back: bytes equal to these mean the write
    /// landed; the expected generation still stored means it did not, and
    /// a retry with the same expected ETag is then safe (a late landing of
    /// the first attempt succeeds only while that ETag is still stored,
    /// and writes the same bytes).
    pub fn put_if_match(
        self: *S3Client,
        level: u8,
        identity: ltx.FileIdentity,
        created_at_ms: i64,
        bytes: []const u8,
        expected_etag: []const u8,
    ) ConditionalWriteError!void {
        try self.check_settled();
        if (self.has_active_write()) return error.InvalidState;
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
            .{
                .payload = self.send_workspace[0..bytes.len],
                .metadata_ms = created_at_ms,
                .conditional = .{ .match_etag = expected_etag },
                .publication = .indeterminate_after_send,
            },
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
        try self.check_settled();
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
        replay: Replay = .none,
    };

    const Publication = enum {
        definite,
        /// Once sent, an attempt without a definite answer (a lost answer,
        /// a 5xx) may have landed: the request ends `PublicationIndeterminate`.
        indeterminate_after_send,
    };

    /// Whether a request may be sent again after an attempt that may have
    /// taken effect, where its method or its publication says no.
    const Replay = enum {
        none,
        /// The payload is bytes only this writer publishes at this key, so
        /// sending them again writes what a late landing would. Such a
        /// request stays indeterminate once an attempt was, until a resend
        /// is answered 2xx (`RequestState`).
        same_bytes,
        /// An attempt that took effect leaves only something nothing uses:
        /// a multipart initiation whose upload id never came back.
        orphan_only,
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
        /// The `Content-Length` header when present: for a HEAD, the
        /// object's size.
        content_length: ?u64 = null,
    };

    /// Signs and performs one request, retrying under the policy what may
    /// pass (`judge_attempt`): each attempt is shown to the observer, a
    /// pooled connection idle past `Config.max_idle_reuse_ms` is closed
    /// before an attempt, and every pooled connection is closed after any
    /// transport failure, retried or not. The response body, when
    /// requested, is read fully into `body_destination` before the
    /// connection returns to the pool, so the returned bytes stay valid
    /// afterwards. A request that is a publication ends
    /// `PublicationIndeterminate` once any attempt may have landed,
    /// whatever ends it but a same-bytes resend's success.
    fn perform(
        self: *S3Client,
        method: std.http.Method,
        key: []const u8,
        query: []const u8,
        options: RequestOptions,
    ) ConditionalWriteError!Outcome {
        switch (options.conditional) {
            .none => {},
            .create_only => {
                std.debug.assert(method == .PUT);
                std.debug.assert(options.publication == .indeterminate_after_send);
            },
            .match_etag => if (method == .GET) {
                std.debug.assert(options.byte_range != null);
                std.debug.assert(options.publication == .definite);
            } else {
                std.debug.assert(method == .PUT);
                std.debug.assert(options.publication == .indeterminate_after_send);
            },
        }
        self.last_parse_failure = "";
        var state: RequestState = .{ .replay = options.replay };
        var first_ms: u64 = 0;
        var attempt: u32 = 1;
        while (true) : (attempt += 1) {
            const begun = self.begin_attempt(method, key, query, attempt);
            if (attempt == 1) first_ms = begun.start_ms;
            var trace: AttemptTrace = .{};
            const result = self.perform_once(method, key, query, options, begun.sign_ms, &trace);
            const failure: ?ConditionalWriteError = if (result) |_| null else |err| err;
            const ending = judge_attempt(method, options, failure, trace);
            state.note(ending);
            const delay = if (ending.retryable) self.retry_delay(attempt, ending.cause) else null;
            self.end_attempt(&begun.attempt, &trace, ending.reported(failure), first_ms, delay != null);
            // A store that restarted stales every pooled connection, and a
            // request that failed while it was sent leaves its dead one in
            // the pool: the next request, retried or not, opens a new one.
            if (ending.transport) self.drop_pooled_connections();
            const pause_ms = delay orelse return state.finish(result);
            self.config.retry.?.sleep_ms(pause_ms) catch |err| return state.fail(err);
        }
    }

    /// The policy's pause before attempt `attempt + 1`, or null when the
    /// attempts are spent or the policy says stop.
    fn retry_delay(self: *const S3Client, attempt: u32, cause: RetryCause) ?u64 {
        const policy = self.config.retry orelse return null;
        if (attempt >= policy.max_attempts) return null;
        return policy.next_delay_ms_fn(policy.context, attempt, cause);
    }

    /// Close every pooled connection: the next attempt opens a new one.
    fn drop_pooled_connections(self: *S3Client) void {
        const pool = &self.http.connection_pool;
        if (pool.free_len == 0) return;
        const size = pool.free_size;
        pool.resize(self.io, 0) catch {};
        pool.resize(self.io, size) catch {};
    }

    /// One attempt about to start, as the observer sees it, its start on
    /// the steady clock, and the wall-clock time it is signed at. The pooled
    /// connections are closed first when the client sat idle past
    /// `Config.max_idle_reuse_ms`; an open pooled connection is the one the
    /// attempt takes.
    fn begin_attempt(
        self: *S3Client,
        method: std.http.Method,
        key: []const u8,
        query: []const u8,
        attempt: u32,
    ) Begun {
        const now_ms = self.steady_now_ms();
        if (self.last_attempt_end_ms) |end_ms| {
            const limit_ms = self.config.max_idle_reuse_ms;
            if (limit_ms != 0 and now_ms -| end_ms > limit_ms) self.drop_pooled_connections();
        }
        const begun: Begun = .{
            .attempt = .{
                .method = method,
                .key = key,
                .query = query,
                .attempt = attempt,
                .reused = self.http.connection_pool.free_len > 0,
                .idle_ms = if (self.last_attempt_end_ms) |end_ms| now_ms -| end_ms else 0,
            },
            .start_ms = now_ms,
            .sign_ms = self.config.clock.now_ms(),
        };
        if (self.config.observer) |observer| observer.begin_fn(observer.context, &begun.attempt);
        return begun;
    }

    /// Note when an attempt ended, and show the observer how.
    fn end_attempt(
        self: *S3Client,
        attempt: *const Attempt,
        trace: *const AttemptTrace,
        failure: ?ConditionalWriteError,
        first_ms: u64,
        will_retry: bool,
    ) void {
        const end_ms = self.steady_now_ms();
        self.last_attempt_end_ms = end_ms;
        const observer = self.config.observer orelse return;
        const end: AttemptEnd = .{
            .attempt = attempt,
            .stage = trace.stage,
            .status = trace.status,
            .s3_code = trace.s3_code,
            .failure = failure,
            .cause = trace.cause,
            .elapsed_ms = end_ms -| first_ms,
            .will_retry = will_retry,
        };
        observer.end_fn(observer.context, &end);
    }

    /// Now on the clock that measures the time between attempts.
    fn steady_now_ms(self: *const S3Client) u64 {
        const steady = self.config.steady_clock orelse self.config.clock;
        return steady.now_ms();
    }

    const Begun = struct {
        attempt: Attempt,
        /// On the steady clock.
        start_ms: u64,
        /// On `Config.clock`.
        sign_ms: u64,
    };

    /// How far one attempt got, for its observer and its retry decision.
    const AttemptTrace = struct {
        stage: Stage = .connect,
        /// The answer's status; 0 until one arrives.
        status: u16 = 0,
        /// The code of an error answer's body.
        s3_code: []const u8 = "",
        /// The transport's own error under a failure.
        cause: ?anyerror = null,
    };

    /// How one attempt ended, as the retry loop weighs it.
    const Ending = struct {
        /// It may be sent again, if the policy allows: nothing was sent,
        /// or it failed in a way that may pass and sending it again is
        /// safe for this request.
        retryable: bool,
        /// The store may have done what it asked, though no answer said
        /// so: a publication that was sent and got no definite answer.
        indeterminate: bool,
        /// The transport failed (no answer came, or none that parsed): the
        /// retry opens a new connection.
        transport: bool,
        cause: RetryCause,

        /// The attempt's failure as the observer is told it: an attempt
        /// that may have landed is `PublicationIndeterminate`.
        fn reported(ending: Ending, failure: ?ConditionalWriteError) ?ConditionalWriteError {
            const err = failure orelse return null;
            return if (ending.indeterminate) error.PublicationIndeterminate else err;
        }
    };

    /// Weigh one attempt. A connect that failed sent nothing: every
    /// request may be sent again, conditional writes and POSTs too. A
    /// request that was sent and failed on the transport, or was answered
    /// a transient status (`is_transient_status`), may be sent again when
    /// that is safe: a read, a delete or an unconditional PUT that is not
    /// a publication; a POST that can at worst leave an orphan; a
    /// publication only when it replays the same bytes; a conditional PUT
    /// only after a transient 4xx, where the store stored nothing, never
    /// after a 5xx or a lost answer, where it may have. A request that
    /// could not be built (stage `connect` with no cause) never passes.
    fn judge_attempt(
        method: std.http.Method,
        options: RequestOptions,
        failure: ?ConditionalWriteError,
        trace: AttemptTrace,
    ) Ending {
        const publication = options.publication == .indeterminate_after_send;
        if (failure) |err| {
            if (trace.stage == .connect) {
                const refused = trace.cause != null;
                return .{ .retryable = refused, .indeterminate = false, .transport = refused, .cause = .transport };
            }
            const transport = err == error.StorageFailure;
            return .{
                .retryable = transport and may_send_again(method, options, 0),
                .indeterminate = publication,
                .transport = transport,
                .cause = .transport,
            };
        }
        const transient = is_transient_status(trace.status, trace.s3_code);
        return .{
            .retryable = transient and may_send_again(method, options, trace.status),
            .indeterminate = publication and trace.status >= 500,
            .transport = false,
            .cause = .{ .status = trace.status },
        };
    }

    /// Whether a request that was sent may be sent again after it failed
    /// in a way that may pass (`status` 0: no answer came).
    fn may_send_again(method: std.http.Method, options: RequestOptions, status: u16) bool {
        if (options.publication == .indeterminate_after_send) {
            if (options.replay == .same_bytes) return true;
            return options.conditional != .none and status >= 400 and status < 500;
        }
        return switch (method) {
            .GET, .HEAD, .DELETE, .PUT => true,
            .POST => options.replay == .orphan_only,
            else => false,
        };
    }

    /// What the retry loop keeps across one request's attempts. Once an
    /// attempt may have landed, every way out of the loop is
    /// `PublicationIndeterminate`: a later refused connect, a definite
    /// refusal, the policy stopping, the attempts running out, or a pause
    /// that failed. A later attempt's answer says nothing of an earlier
    /// attempt that may still land, but for a 2xx to a same-bytes resend:
    /// the key then holds exactly these bytes, and the earlier attempt,
    /// should it land late, writes them again.
    const RequestState = struct {
        replay: Replay = .none,
        indeterminate: bool = false,

        fn note(self: *RequestState, ending: Ending) void {
            if (ending.indeterminate) self.indeterminate = true;
        }

        fn finish(self: RequestState, result: ConditionalWriteError!Outcome) ConditionalWriteError!Outcome {
            if (!self.indeterminate) return result;
            if (self.replay == .same_bytes) {
                const outcome = result catch return error.PublicationIndeterminate;
                if (outcome.status.class() == .success) return outcome;
            }
            return error.PublicationIndeterminate;
        }

        fn fail(self: RequestState, err: ConditionalWriteError) ConditionalWriteError {
            return if (self.indeterminate) error.PublicationIndeterminate else err;
        }
    };

    /// Signs and performs exactly one request attempt, signed at `now_ms`,
    /// and leaves in `trace` how far it got. A transport failure is
    /// `StorageFailure` at whatever stage; `perform` weighs it.
    fn perform_once(
        self: *S3Client,
        method: std.http.Method,
        key: []const u8,
        query: []const u8,
        options: RequestOptions,
        now_ms: u64,
        trace: *AttemptTrace,
    ) ConditionalWriteError!Outcome {
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

        var path_buffer: [path_workspace_bytes]u8 = undefined;
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
        }) catch |err| {
            trace.cause = err;
            return error.StorageFailure;
        };
        defer request.deinit();

        self.enter_stage(trace, .send);
        const sent = if (options.payload) |body|
            request.sendBodyComplete(body)
        else if (method.requestHasBody())
            // PUT without a payload still carries a zero-length body.
            request.sendBodyComplete(self.send_workspace[0..0])
        else
            request.sendBodiless();
        sent catch |err| {
            trace.cause = transport_cause(&request, err);
            return error.StorageFailure;
        };
        self.enter_stage(trace, .receive_head);
        var response = request.receiveHead(&self.redirect_buffer) catch |err| {
            trace.cause = transport_cause(&request, err);
            return error.StorageFailure;
        };
        return self.take_answer(&request, &response, method, options, trace);
    }

    /// The rest of one attempt once an answer's head arrived: its headers,
    /// the code of an error answer, and a body the caller asked for.
    fn take_answer(
        self: *S3Client,
        request: *std.http.Client.Request,
        response: *std.http.Client.Response,
        method: std.http.Method,
        options: RequestOptions,
        trace: *AttemptTrace,
    ) ConditionalWriteError!Outcome {
        const status = response.head.status;
        trace.status = @backingInt(status);
        self.enter_stage(trace, .headers);
        mark_bodyless_response_complete(request, method, status);
        var etag: ?[]const u8 = null;
        var content_range: ?ContentRange = null;
        var header_iterator = response.head.iterateHeaders();
        while (header_iterator.next()) |header| {
            if (std.ascii.eqlIgnoreCase(header.name, "etag")) {
                if (etag != null or header.value.len == 0 or
                    header.value.len > self.etag_workspace.len)
                {
                    return error.StorageFailure;
                }
                @memcpy(self.etag_workspace[0..header.value.len], header.value);
                etag = self.etag_workspace[0..header.value.len];
            } else if (status == .partial_content and
                std.ascii.eqlIgnoreCase(header.name, "content-range"))
            {
                if (content_range != null) return error.StorageFailure;
                content_range = try parse_content_range(header.value);
            }
        }
        const readable_status = status == .ok or
            (options.byte_range != null and status == .partial_content);
        const content_length = response.head.content_length;
        self.enter_stage(trace, .status);
        if (!readable_status) {
            trace.s3_code = self.read_error_code(request, response, method);
            return .{
                .status = status,
                .etag = etag,
                .content_range = content_range,
                .content_length = content_length,
            };
        }
        const destination = options.body_destination orelse return .{
            .status = status,
            .etag = etag,
            .content_range = content_range,
            .content_length = content_length,
        };
        self.enter_stage(trace, .read_body);
        const reader = response.reader(&self.transfer_buffer);
        const bytes = read_bounded_response_body(reader, destination) catch |err| {
            trace.cause = request.reader.body_err orelse
                transport_cause(request, error.ReadFailed);
            if (options.byte_range != null and err == error.ObjectTooLarge) {
                return error.StorageFailure;
            }
            return err;
        };
        if (options.byte_range != null and bytes.len != destination.len) {
            return error.StorageFailure;
        }
        self.enter_stage(trace, .status);
        return .{
            .status = status,
            .bytes = bytes,
            .etag = etag,
            .content_range = content_range,
            .content_length = content_length,
        };
    }

    /// The `<Code>` of an error answer's body, kept in `s3_code_workspace`
    /// until the next request; empty when none was read. A HEAD's answer
    /// has no body, and a GET's 404 is the usual answer for a missing
    /// object, so neither is read. A request that sent a body never
    /// reuses its connection after an error answer: MinIO closes one after
    /// a PUT's 412 without saying so, and the next request sent on it fails.
    fn read_error_code(
        self: *S3Client,
        request: *std.http.Client.Request,
        response: *std.http.Client.Response,
        method: std.http.Method,
    ) []const u8 {
        const status = response.head.status;
        if (@backingInt(status) < 400 or method == .HEAD) return "";
        if (method.requestHasBody()) request.connection.?.closing = true;
        if (status == .not_found and method == .GET) return "";
        if (response.head.content_length) |length| {
            if (length > max_error_body_bytes) return "";
        }
        var body: [error_body_read_bytes]u8 = undefined;
        const reader = response.reader(&self.transfer_buffer);
        const length = reader.readSliceShort(&body) catch return "";
        const code = xml_text(body[0..length], "<Code>", "</Code>") orelse return "";
        if (code.len == 0 or code.len > self.s3_code_workspace.len) return "";
        for (code) |byte| if (!std.ascii.isAlphanumeric(byte)) return "";
        @memcpy(self.s3_code_workspace[0..code.len], code);
        return self.s3_code_workspace[0..code.len];
    }

    /// Record how far an attempt got, and tell the observer.
    fn enter_stage(self: *S3Client, trace: *AttemptTrace, stage: Stage) void {
        trace.stage = stage;
        const observer = self.config.observer orelse return;
        const stage_fn = observer.stage_fn orelse return;
        stage_fn(observer.context, stage);
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
        // A truncated page without a token is returned as such: `list`
        // walks the level again.
        var next_token: ?[]const u8 = null;
        if (truncated) {
            if (xml_text(xml, "<NextContinuationToken>", "</NextContinuationToken>")) |encoded| {
                next_token = decode_xml_text(encoded, &self.token_workspace) catch |err| {
                    self.last_parse_failure = "a continuation token over 2048 bytes or with an unknown XML entity";
                    return err;
                };
            }
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

/// The transport's own error under `err`: the socket's error when a read
/// or a write of the connection failed.
fn transport_cause(request: *const std.http.Client.Request, err: anyerror) anyerror {
    const connection = request.connection orelse return err;
    if (err == error.ReadFailed) {
        if (connection.stream_reader.err) |socket_err| return socket_err;
    }
    if (err == error.WriteFailed) {
        if (connection.stream_writer.err) |socket_err| return socket_err;
    }
    return err;
}

/// A quoted MD5 in hex, `-`, and a part count of at most 10 digits.
const upload_etag_bytes = 2 + 32 + 1 + 10;

/// The ETag a store gives the object an upload completes: the MD5 of the
/// parts' binary MD5s, then `-` and the part count, quoted. Null when a
/// part's ETag is not a quoted 32-digit hex MD5.
fn upload_etag(state: *const MultipartState, out: *[upload_etag_bytes]u8) ?[]const u8 {
    var md5 = std.crypto.hash.Md5.init(.{});
    for (state.etags[0..state.part_count], state.etag_lengths[0..state.part_count]) |*etag, length| {
        const text = std.mem.trim(u8, etag[0..length], "\"");
        if (text.len != 32) return null;
        var digest: [std.crypto.hash.Md5.digest_length]u8 = undefined;
        _ = std.fmt.hexToBytes(&digest, text) catch return null;
        md5.update(&digest);
    }
    var sum: [std.crypto.hash.Md5.digest_length]u8 = undefined;
    md5.final(&sum);
    return std.fmt.bufPrint(out, "\"{x}-{d}\"", .{ &sum, state.part_count }) catch null;
}

fn abort_status_is_clean(status: std.http.Status) bool {
    return switch (status) {
        .ok, .no_content, .not_found => true,
        else => false,
    };
}

/// Whether an answer's status is a failure that may pass: 500, 502, 503
/// and 504 (the store or a proxy in front of it failed or is busy), 429 and
/// 408 (slow down; the client was slow), and 400 when its code says the
/// client was slow or the store lost the body (`RequestTimeout`,
/// `IncompleteBody`; MinIO answers a PUT that races a delete of its
/// directory this way). Not 501, 505 or 507, nor any other 4xx: those do
/// not change on their own.
pub fn is_transient_status(status: u16, s3_code: []const u8) bool {
    return switch (status) {
        500, 502, 503, 504, 429, 408 => true,
        400 => std.mem.eql(u8, s3_code, "RequestTimeout") or
            std.mem.eql(u8, s3_code, "IncompleteBody"),
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
    // A truncated page may lose its token; `list` walks the level again.
    const lost = try client.parse_list_page(
        "<ListBucketResult><IsTruncated>true</IsTruncated></ListBucketResult>",
    );
    try std.testing.expect(lost.truncated and lost.next_token == null);
}

test "list parsing keeps a continuation token made from a 1,024-byte key" {
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
    // MinIO's token is the base64 of the last key and a suffix of up to
    // 40 bytes: 1,420 bytes for a 1,024-byte key.
    var page: [token_workspace_bytes + 128]u8 = undefined;
    const open = "<ListBucketResult><IsTruncated>true</IsTruncated><NextContinuationToken>";
    const close = "</NextContinuationToken></ListBucketResult>";
    @memcpy(page[0..open.len], open);
    @memset(page[open.len..][0..1420], 'Q');
    @memcpy(page[open.len + 1420 ..][0..close.len], close);
    const kept = try client.parse_list_page(page[0 .. open.len + 1420 + close.len]);
    try std.testing.expectEqual(@as(usize, 1420), kept.next_token.?.len);
    // A token past the workspace fails the page.
    @memset(page[open.len..][0 .. token_workspace_bytes + 1], 'Q');
    @memcpy(page[open.len + token_workspace_bytes + 1 ..][0..close.len], close);
    try std.testing.expectError(
        error.StorageFailure,
        client.parse_list_page(page[0 .. open.len + token_workspace_bytes + 1 + close.len]),
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
        fn next(context: *anyopaque, attempt: u32, cause: RetryCause) ?u64 {
            _ = attempt;
            const self: *@This() = @ptrCast(@alignCast(context));
            self.calls += 1;
            return switch (cause) {
                .transport => 10,
                .status => |code| if (code == 429) 20 else null,
            };
        }

        fn sleep(_: *anyopaque, _: u64) Error!void {}
    };
    var probe = Probe{};
    var send_workspace: [1]u8 = undefined;
    var clock_context: u8 = 0;
    const FixedClock = struct {
        fn now_ms(_: *anyopaque) u64 {
            return 0;
        }
    };
    var client = try S3Client.init(std.testing.allocator, std.testing.io, .{
        .host = "127.0.0.1",
        .port = 9000,
        .bucket = "test",
        .access_key = "key",
        .secret_key = "secret",
        .clock = .{ .context = &clock_context, .now_ms_fn = FixedClock.now_ms },
        .retry = .{ .context = &probe, .next_delay_ms_fn = Probe.next, .sleep_ms_fn = Probe.sleep, .max_attempts = 3 },
    }, &send_workspace);
    defer client.deinit();

    // Within the budget the callback's delay; at the last attempt none.
    try std.testing.expectEqual(@as(?u64, 10), client.retry_delay(1, .transport));
    try std.testing.expectEqual(@as(?u64, null), client.retry_delay(3, .transport));
    // The callback stops a status it will not retry.
    try std.testing.expectEqual(@as(?u64, null), client.retry_delay(1, .{ .status = 503 }));
    try std.testing.expectEqual(@as(?u64, 20), client.retry_delay(1, .{ .status = 429 }));
    try std.testing.expectEqual(@as(u32, 3), probe.calls);

    const refused: S3Client.AttemptTrace = .{ .stage = .connect, .cause = error.ConnectionRefused };
    const lost: S3Client.AttemptTrace = .{ .stage = .receive_head, .cause = error.HttpConnectionClosing };
    const plain: S3Client.RequestOptions = .{};
    const create_only: S3Client.RequestOptions = .{ .conditional = .create_only, .publication = .indeterminate_after_send };
    const judge = S3Client.judge_attempt;
    // A connect that failed sent nothing: every request, POST and
    // conditional PUT too.
    try std.testing.expect(judge(.POST, plain, error.StorageFailure, refused).retryable);
    try std.testing.expect(judge(.PUT, create_only, error.StorageFailure, refused).retryable);
    // A request that could not be built never passes.
    try std.testing.expect(!judge(.GET, plain, error.StorageFailure, .{ .stage = .connect }).retryable);
    // Once sent, reads, deletes and unconditional PUTs go again; POSTs do not.
    try std.testing.expect(judge(.GET, plain, error.StorageFailure, lost).retryable);
    try std.testing.expect(judge(.DELETE, plain, error.StorageFailure, lost).retryable);
    try std.testing.expect(!judge(.POST, plain, error.StorageFailure, lost).retryable);
    // A multipart initiation may go again when a lost one leaves only an
    // orphan upload.
    const initiation: S3Client.RequestOptions = .{ .replay = .orphan_only };
    try std.testing.expect(judge(.POST, initiation, error.StorageFailure, lost).retryable);
    try std.testing.expect(judge(.POST, initiation, null, .{ .stage = .status, .status = 503 }).retryable);
    try std.testing.expect(!judge(.POST, initiation, error.StorageFailure, lost).indeterminate);
    // A conditional read keeps its generation on retry.
    const match_read: S3Client.RequestOptions = .{ .conditional = .{ .match_etag = "\"generation\"" }, .byte_range = .{ .start_bytes = 0, .end_bytes = 0 } };
    try std.testing.expect(judge(.GET, match_read, error.StorageFailure, lost).retryable);
    // A conditional PUT goes again after a transient 4xx only.
    try std.testing.expect(!judge(.PUT, create_only, error.StorageFailure, lost).retryable);
    try std.testing.expect(judge(.PUT, create_only, null, .{ .stage = .status, .status = 429 }).retryable);
    try std.testing.expect(judge(.PUT, create_only, null, .{ .stage = .status, .status = 400, .s3_code = "IncompleteBody" }).retryable);
    try std.testing.expect(!judge(.PUT, create_only, null, .{ .stage = .status, .status = 503 }).retryable);
    // A local failure after the answer (a body too large) is final.
    try std.testing.expect(!judge(.GET, plain, error.ObjectTooLarge, .{ .stage = .read_body }).retryable);
}

test "only a publication's attempt without a definite answer is indeterminate" {
    const judge = S3Client.judge_attempt;
    const lost: S3Client.AttemptTrace = .{ .stage = .receive_head, .cause = error.HttpConnectionClosing };
    const refused: S3Client.AttemptTrace = .{ .stage = .connect, .cause = error.ConnectionRefused };
    const publication: S3Client.RequestOptions = .{ .publication = .indeterminate_after_send };
    try std.testing.expect(!judge(.PUT, .{}, error.StorageFailure, lost).indeterminate);
    try std.testing.expect(judge(.PUT, publication, error.StorageFailure, lost).indeterminate);
    try std.testing.expect(judge(.POST, publication, error.ObjectTooLarge, .{ .stage = .read_body }).indeterminate);
    try std.testing.expect(!judge(.PUT, publication, error.StorageFailure, refused).indeterminate);
    // A 5xx may hide a write; a 4xx is the store's refusal.
    try std.testing.expect(judge(.PUT, publication, null, .{ .stage = .status, .status = 500 }).indeterminate);
    try std.testing.expect(judge(.PUT, publication, null, .{ .stage = .status, .status = 507 }).indeterminate);
    try std.testing.expect(!judge(.PUT, publication, null, .{ .stage = .status, .status = 429 }).indeterminate);
    try std.testing.expect(!judge(.PUT, publication, null, .{ .stage = .status, .status = 400 }).indeterminate);
    try std.testing.expect(!judge(.PUT, publication, null, .{ .stage = .status, .status = 200 }).indeterminate);
    // Without a replay of the same bytes, nothing that may have landed is
    // sent again.
    try std.testing.expect(!judge(.PUT, publication, error.StorageFailure, lost).retryable);
    try std.testing.expect(!judge(.PUT, publication, null, .{ .stage = .status, .status = 503 }).retryable);
    const replay: S3Client.RequestOptions = .{ .publication = .indeterminate_after_send, .replay = .same_bytes };
    try std.testing.expect(judge(.PUT, replay, error.StorageFailure, lost).retryable);
    try std.testing.expect(judge(.PUT, replay, null, .{ .stage = .status, .status = 503 }).retryable);
    // The observer is told an attempt that may have landed as such.
    const ending = judge(.PUT, publication, error.StorageFailure, lost);
    try std.testing.expectEqual(@as(?ConditionalWriteError, error.PublicationIndeterminate), ending.reported(error.StorageFailure));
}

test "an indeterminate attempt stays indeterminate until a same-bytes resend is answered 2xx" {
    const judge = S3Client.judge_attempt;
    const replay: S3Client.RequestOptions = .{ .publication = .indeterminate_after_send, .replay = .same_bytes };
    const lost: S3Client.AttemptTrace = .{ .stage = .receive_head, .cause = error.HttpConnectionClosing };
    // Attempt 1's answer was lost; attempt 2 was answered 200: the key holds
    // exactly these bytes, and attempt 1 landing late writes them again.
    var landed: S3Client.RequestState = .{ .replay = .same_bytes };
    landed.note(judge(.PUT, replay, error.StorageFailure, lost));
    landed.note(judge(.PUT, replay, null, .{ .stage = .status, .status = 200 }));
    try std.testing.expectEqual(std.http.Status.ok, (try landed.finish(.{ .status = .ok })).status);
    // Attempt 1 was answered 503, and attempt 2 too, the last the policy
    // allowed.
    var busy: S3Client.RequestState = .{ .replay = .same_bytes };
    busy.note(judge(.PUT, replay, null, .{ .stage = .status, .status = 503 }));
    busy.note(judge(.PUT, replay, null, .{ .stage = .status, .status = 503 }));
    try std.testing.expectError(error.PublicationIndeterminate, busy.finish(.{ .status = .service_unavailable }));
    // Attempt 2's connect was refused, and the policy stopped there.
    var refused: S3Client.RequestState = .{ .replay = .same_bytes };
    refused.note(judge(.PUT, replay, error.StorageFailure, lost));
    const refused_ending = judge(.PUT, replay, error.StorageFailure, .{ .stage = .connect, .cause = error.ConnectionRefused });
    try std.testing.expect(!refused_ending.indeterminate);
    refused.note(refused_ending);
    try std.testing.expectError(error.PublicationIndeterminate, refused.finish(error.StorageFailure));
    // Attempt 2 was answered 403: a definite refusal of attempt 2 only.
    var answered: S3Client.RequestState = .{ .replay = .same_bytes };
    answered.note(judge(.PUT, replay, error.StorageFailure, lost));
    answered.note(judge(.PUT, replay, null, .{ .stage = .status, .status = 403 }));
    try std.testing.expectError(error.PublicationIndeterminate, answered.finish(.{ .status = .forbidden }));
    // A pause that failed (a stopping host) ends it the same way.
    try std.testing.expectEqual(error.PublicationIndeterminate, answered.fail(error.StorageFailure));
    // Without an earlier indeterminate attempt, the result stands.
    var definite: S3Client.RequestState = .{ .replay = .same_bytes };
    definite.note(judge(.PUT, replay, null, .{ .stage = .status, .status = 403 }));
    try std.testing.expectEqual(std.http.Status.forbidden, (try definite.finish(.{ .status = .forbidden })).status);
}

test "400 RequestTimeout and IncompleteBody are transient, 501 is not" {
    for ([_]u16{ 500, 502, 503, 504, 429, 408 }) |status| {
        try std.testing.expect(is_transient_status(status, ""));
    }
    try std.testing.expect(is_transient_status(400, "RequestTimeout"));
    try std.testing.expect(is_transient_status(400, "IncompleteBody"));
    try std.testing.expect(!is_transient_status(400, "InvalidArgument"));
    try std.testing.expect(!is_transient_status(400, ""));
    for ([_]u16{ 200, 206, 403, 404, 409, 412, 416, 501, 505, 507 }) |status| {
        try std.testing.expect(!is_transient_status(status, "RequestTimeout"));
    }
}

test "an upload's ETag is the MD5 of its parts' MD5s and their count" {
    var state: MultipartState = .{ .level = 0, .identity = .{ .min_txid = .init(1), .max_txid = .init(1) } };
    // Parts "a" and "b"; the answer is from Python's hashlib.
    for ([_][]const u8{ "\"0cc175b9c0f1b6a831c399e269772661\"", "\"92EB5FFEE6AE2FEC3AD71C777531578F\"" }) |etag| {
        @memcpy(state.etags[state.part_count][0..etag.len], etag);
        state.etag_lengths[state.part_count] = @intCast(etag.len);
        state.part_count += 1;
    }
    var out: [upload_etag_bytes]u8 = undefined;
    try std.testing.expectEqualStrings("\"96e024ba2074fe77e8e965ba43a704be-2\"", upload_etag(&state, &out).?);
    // A part ETag that is not an MD5 (KMS encryption) gives none.
    const kms = "\"not-an-md5\"";
    @memcpy(state.etags[1][0..kms.len], kms);
    state.etag_lengths[1] = kms.len;
    try std.testing.expect(upload_etag(&state, &out) == null);
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
