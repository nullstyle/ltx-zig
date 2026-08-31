# Replication guide

This document is the deployment contract for the replication modules:
`ltx_wal`, `ltx_object`, `ltx_s3`, `ltx_replica`, `ltx_capture`,
`ltx_resources`, and `ltx_replication`. The
roadmap that produced them is [`replication-roadmap.md`](replication-roadmap.md);
the codec trust model they build on is [`design.md`](design.md).

## Module map

| Module | Role |
| --- | --- |
| `ltx_wal` | SQLite WAL bytes to committed page maps, salt scans, and mid-WAL resume. Standalone; no filesystem or SQLite linkage. |
| `ltx_object` | The storage-neutral object contract, bounded sequential readers over exact ranges, transactional writer sessions, the filesystem backend in the Litestream layout, and the backend-agnostic conformance suite. |
| `ltx_s3` | The S3 backend: path-style and virtual-host SigV4, TLS, bounded retry, paginated prefix-scoped listings, exact ranged reads, object write/delete, conditional writes, automatic single/multipart transactional upload, and bucket creation. |
| `ltx_replica` | The level ladder, restore planning, compaction and retention planners, and the restore and compaction executors over `ltx` codecs. |
| `ltx_capture` | The SQLite capture session: WAL-mode lifecycle, Litestream control tables, a checkpoint-blocking read lock, snapshot/incremental/fallback transitions, seeded continuation, mid-WAL resume, and three-tier passive checkpointing. Links SQLite through a hand-written extern surface provided by the host build. |
| `ltx_resources` | Checked public resource formulas and fixed-arena binding for byte and typed workspaces. |
| `ltx_replication` | The synchronous per-database controller: startup restore, capture position, restore, one adjacent-level maintenance quantum, and safe retention. |

Every module is synchronous, allocation-free after initialization (the S3
HTTP transport's pooled connections are the single exception), and driven by
explicit limits, workspaces, and timestamps. Consult
[`resource-budgets.md`](resource-budgets.md) for workspace formulas.

## What the library guarantees

- A captured file is only published after its LTX bytes encode successfully;
  a restore only publishes an image after the full LTX verification chain and
  the staged-image checksum (when checksums are enabled) pass.
- Restores require exact TXID continuity from the empty position; compaction
  requires exact continuity across inputs and a single checksum mode. Neither
  performs history repair.
- Restore-to-path publishes through private staging with tmp-write, sync, and
  rename per transition.
- Captured L0 files use the no-checksum Litestream profile; the object
  layout, level names, filenames, and `litestream-timestamp` metadata match
  Litestream's on-disk and object-store layouts so external tooling
  (including the Litestream v0.5.16 reader qualified in
  [`upstream.md`](upstream.md)) interoperates.
- Filesystem and S3 producers stream encoded output into private transactional
  staging. `finish` is the requested object publication boundary; encoding or
  transport failure does not advance capture position or delete compacted
  inputs. A post-commit confirmation failure reports
  `PublicationIndeterminate`; reconcile that exact identity before retrying or
  discarding its source. In particular, loss of the S3
  `CompleteMultipartUpload` acknowledgement can mean that the object is
  already visible even though the client did not receive the success body.
- Restore and compaction consume each listed object through a caller-owned
  sequential read window. Every adapter must fill each requested range exactly
  and independently reject a current total object length different from the
  listing. No page, position, or output becomes trusted before the decoder
  verifies the complete index, trailer, checksum, and logical EOF.

## What the host owns

- Scheduling and concurrency across databases, and pooling the per-operation
  workspaces (a capture set, a restore set, and compaction input sets) across
  actors.
- Durability and acknowledgement policy: `Session.sync` can be called per
  committed transaction; whether a write is acknowledged before or after the
  upload is the host's decision.
- Lease and fencing policy for actor migration. `S3Client.put_if_absent`
  provides create-only fencing and `object_etag` + `put_if_match` provide
  replace-if-generation renewal (a shifted generation fails with
  `ETagMismatch`); turning these into a lease protocol is the host's
  decision. Conditional PUTs are attempted once and report
  `PublicationIndeterminate` when delivery fails after sending begins. A
  `RetryPolicy` covers transient transport failures and retryable statuses only
  on unambiguous idempotent requests.
- Checkpoint policy: configure any combination of
  `checkpoint_threshold_bytes`, `checkpoint_interval_ms`, and
  `checkpoint_max_frames`, or call `Session.checkpoint_passive` explicitly.
  The host still decides when capture runs and should monitor
  `Session.checkpoint_pending` for deferred automatic maintenance.

## Producer lifecycle

```zig
var session = try ltx_capture.Session.init(dir, io, "app.db",
    codec_limits, wal_limits, client);
defer session.finish();
session.checkpoint_threshold_bytes = 8 << 20;
// ... application writes through its own connection ...
const pages = try session.sync(&workspaces, now_ms);
```

The first `sync` is a snapshot; later syncs are incrementals while the WAL
segment continues. A checkpoint the session initiated (through the threshold
or an explicit call) restarts the segment and the next committed frames still
capture as an incremental. Any foreign discontinuity — another process
checkpointing, a replaced WAL — falls back to a fresh snapshot, which is
always safe because missing pages are read from the database file. A WAL
larger than the workspace is rejected, never partially read.

Automatic checkpoint failure never masks a capture that has already published
and advanced its position. Instead, `checkpoint_pending` remains true and a
later sync retries the PASSIVE checkpoint. Manual `checkpoint_passive` reports
`CheckpointIncomplete` when SQLite could not checkpoint every logged frame.

When the object adapter implements transactional sessions, `output_storage`
may be empty because encoder bytes flow directly to private backend staging.
Adapters that expose only whole-object `write` retain the fixed buffered
fallback and must supply `Limits.max_output_bytes` of output capacity. Every
simultaneously live workspace must be disjoint; opaque adapter storage such as
an S3 send buffer is also caller-owned and cannot be checked through the
storage-neutral client interface.

`Config.read_workspace_bytes` sets the required capacity of the restore read
window and every simultaneous compaction-input read window. It must be nonzero
and no larger than `Limits.max_input_bytes`. Object admission still uses
`max_input_bytes`, while `max_compaction_input_bytes` continues to bound the
aggregate source plan; neither value is a request-buffer allocation. A 64 KiB
window is a practical local starting point, while remote deployments can use a
larger fixed window to reduce range-request count.

## Controller lifecycle

```zig
var controller = try ltx_replication.Controller.init(options, &resources);
defer controller.finish();

_ = try controller.sync(now_ms);
_ = try controller.maintain(1); // one caller-selected adjacent-level quantum
const durable = try controller.position();
```

`Startup.require_empty` rejects any pre-existing object tree,
`Startup.verified_local` seeds a host-verified image position, and
`Startup.restore_latest` restores and verifies the latest chain before SQLite
opens. Restore-latest requires the host to quiesce the target and rejects an
existing `-wal`, `-shm`, or `-journal` sidecar. Runtime `restore` likewise
requires a distinct host-quiesced backend target. The controller centralizes
the common synchronous path, while `ltx_capture` and `ltx_replica` remain
public for custom policy.

Maintenance publishes and fully verifies the compacted upper-level object
before it attempts to delete any lower-level source. If deletion is
interrupted, that controller is poisoned: finish it and create a fresh
controller rather than continuing to use uncertain in-memory state. The fresh
controller rebuilds its view from object listings, reads and fully verifies
each candidate covering upper-level LTX object, and only then reconciles
retention. It deletes only selected lower-level objects whose exact TXID range
the verified object covers. Snapshot maintenance also removes covered older
snapshots after that same verification, including on a restart where source
cleanup had already completed. Retained sources and snapshots are safe
duplicates until reconciliation completes. A restore across the mixed
pre-cleanup tree must still verify to the same durable latest position and
database image. A cleanup-only call returns
`MaintenanceResult.reconciled` before it compacts an uncovered tail; call
`maintain` again to continue the bounded work.

For S3 multipart publication, treat `PublicationIndeterminate` as a distinct
reconciliation state, not as permission to upload the same logical transition
blindly. A lost completion acknowledgement may leave either an unfinished
upload or a published object. The write session is poisoned and performs a
best-effort abort; a missing upload is already clean, while a failed abort
retains cleanup state and blocks new writes until an explicit cleanup retry
succeeds. The host must inspect the exact object identity and validate its LTX
contents before advancing durable position or deleting source objects.

## Consumer lifecycle

```zig
// list every level, then:
const plan = try ltx_replica.calc_restore_plan(&lists, target_txid, &plan_storage);
var job = ltx_replica.RestoreJob{ ... };
const position = try job.run(plan);
```

`RestoreJob.read_workspace` is one bounded window, not whole-object storage.
Each `CompactionJobInput` similarly supplies `read_workspace`; the executor
owns the buffered reader state and interleaves the fixed windows as the
compactor advances its inputs. Both executors preflight their complete source
metadata against every mutable workspace before the first read, so a refill
cannot corrupt a later planned identity after earlier publication.

Compaction and retention follow the same shape: `plan_compaction` selects the
destination-continuing prefix, `CompactionJob.run` merges it through the
codec compactor and publishes the verified output, and `plan_retention`
names the lower-level files fully absorbed by a durable higher level.

## Gates

- `mise exec -- zig build test` — hermetic, network-free, includes the
  filesystem backend conformance suite and all planner truth tables.
- `mise exec -- zig build capture-integration -Doptimize=ReleaseSafe` — live
  host SQLite: capture, checkpoint continuation, bounded-WAL, and restores
  verified by querying restored images read-only.
- `mise run s3-integration` — the same conformance suite plus plan, TLS,
  conditional-write, retry, multipart, and supported virtual-host coverage
  against isolated pinned local MinIO instances with real SigV4.
- `mise exec -- zig build litestream-interop -Dlitestream=<path>` — the
  pinned Litestream v0.5.16 binary restores Zig-compacted fixtures and a
  live `ltx_capture` tree to byte-identical images.
- `mise exec -- zig build example-replicate-once` — the runnable consumer
  template covering the whole lifecycle.
- `mise exec -- zig build scale-check -Dscale-mb=512` — opt-in scale
  qualification: capture, compaction, and restore of a real database with
  per-phase throughput, byte-identical image, and row-count verification.

## Measured throughput (512 MiB, 4096-byte pages, local filesystem)

From the scale tool on the development host, one thread, ReleaseSafe:
capture with per-batch syncs 63–74 MiB/s of database, level compaction
about 62–72 MiB/s of logical volume, and full restore 377–395 MiB/s
(1.8 s for a 684 MiB image). The restored file is byte-identical to the
checkpointed original across 512 compacted L0 files. Remote object stores
will be bounded by network rather than these codec paths; re-run the tool
per deployment and record the numbers where this section points.

The M7 bounded-read qualification repeatedly ran the same ReleaseSafe tool at
its required 64 MiB sprint size with 64 KiB input windows. Observed throughput
was 63.5–66.9 MiB/s for capture, 146.7–157.2 MiB/s for L0-to-L1 compaction,
and 371.1–397.7 MiB/s for restore. Every run compacted 64 L0 files and restored
a byte-identical 85.6 MiB image. These scale-sensitive numbers supplement
rather than replace the 512 MiB series above.

## Known boundaries

- `ltx_s3`: both path-style and virtual-host addressing
  (`virtual_host = true`). TLS uses the standard-library client against
  `ca_file` or the system bundle, and multipart uploads stream one part at
  a time through the send workspace (single in-flight upload per client,
  parts numbered from one without gaps, every part but the last at the
  store's 5 MiB minimum). Transactional writers buffer at most one part and
  automatically use a single PUT for small objects or multipart for larger
  ones. Sequential input uses signed single-range GETs, accepts only exact
  `206 Partial Content` responses, and validates `Content-Range` start, end,
  and total length against the listing before returning bytes. Listings
  request at most eight keys per page so the maximum S3 key and
  its XML expansion remain inside the fixed 64 KiB response workspace, and
  `Config.max_listing_pages` bounds total remote pagination even when foreign
  keys are ignored. Failed multipart aborts retain their upload identity and
  block new writes until an explicit cleanup retry or `deinit` succeeds. If
  multipart initiation reaches the store but its acknowledgement is lost, the
  client never receives an upload ID and therefore has no local cleanup handle;
  deployments must bound those unknown incomplete uploads with store-side
  lifecycle cleanup.
- `ltx_object.ObjectReader` relies on each `Client.read_range` adapter to
  verify the listed total length on every range, but it does not pin a backend
  generation across ranges. The host's existing ownership/fencing boundary
  must prevent replacement of the same object key from the first range through
  final LTX verification. Supporting unfenced cross-writer reads would require
  a future generation-token or conditional ETag read-session seam.
- `ltx_capture`: passive checkpointing only — no writer barrier, which the
  single-writer-per-database model makes unnecessary. Three tiers bound the
  WAL: `checkpoint_threshold_bytes`, `checkpoint_interval_ms`, and
  `checkpoint_max_frames`. Syncs on a continuing segment resume mid-WAL
  from the last captured frame; only the first capture and post-restart
  syncs scan from the beginning. After restoring a replica, call
  `seed_position` before the first sync so the continuation numbers its
  TXIDs after the recovered position instead of restarting at one.
- Restore requires the plan's first file to start at TXID 1 from the empty
  position; chains that begin mid-history need an earlier snapshot.
