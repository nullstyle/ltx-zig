# Replication guide

This document is the deployment contract for the replication modules:
`ltx_wal`, `ltx_object`, `ltx_s3`, `ltx_replica`, and `ltx_capture`. The
roadmap that produced them is [`replication-roadmap.md`](replication-roadmap.md);
the codec trust model they build on is [`design.md`](design.md).

## Module map

| Module | Role |
| --- | --- |
| `ltx_wal` | SQLite WAL bytes to committed page maps, salt censes, and mid-WAL resume. Standalone; no filesystem or SQLite linkage. |
| `ltx_object` | The storage-neutral object contract, the filesystem backend in the Litestream layout, and the backend-agnostic conformance suite. |
| `ltx_s3` | The S3 backend: path-style SigV4, paginated prefix-scoped listings, object read/write/delete, bucket creation. |
| `ltx_replica` | The level ladder, restore planning, compaction and retention planners, and the restore and compaction executors over `ltx` codecs. |
| `ltx_capture` | The SQLite capture session: WAL-mode lifecycle, Litestream control tables, a checkpoint-blocking read lock, snapshot/incremental/fallback transitions, and passive checkpointing. Links SQLite through a hand-written extern surface provided by the host build. |

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

## What the host owns

- Scheduling and concurrency across databases, and pooling the per-operation
  workspaces (a capture set, a restore set, and compaction input sets) across
  actors.
- Durability and acknowledgement policy: `Session.sync` can be called per
  committed transaction; whether a write is acknowledged before or after the
  upload is the host's decision.
- Lease and fencing policy for actor migration. `S3Client.put_if_absent`
  provides the conditional-write primitive (`If-None-Match: *`, first writer
  wins, contenders receive `ObjectExists`); turning it into a lease protocol
  is the host's decision.
- Checkpoint cadence beyond the byte threshold: call
  `Session.checkpoint_passive` (or set `checkpoint_threshold_bytes`) as your
  retention loop requires.

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

## Consumer lifecycle

```zig
// list every level, then:
const plan = try ltx_replica.calc_restore_plan(&lists, target_txid, &plan_storage);
var job = ltx_replica.RestoreJob{ ... };
const position = try job.run(plan);
```

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
- `mise run s3-integration` — the same conformance suite plus a plan round
  trip against a local MinIO server with real SigV4.
- `mise exec -- zig build litestream-interop -Dlitestream=<path>` — the
  pinned Litestream v0.5.16 binary restores Zig-compacted fixtures and a
  live `ltx_capture` tree to byte-identical images.
- `mise exec -- zig build example-replicate-once` — the runnable consumer
  template covering the whole lifecycle.

## Known boundaries

- `ltx_s3`: virtual-host addressing is not implemented; path-style only.
  TLS uses the standard-library client against `ca_file` or the system
  bundle, and multipart uploads stream one part at a time through the send
  workspace (single in-flight upload per client, parts numbered from one
  without gaps, every part but the last at the store's 5 MiB minimum).
- `ltx_capture`: passive checkpointing only — no writer barrier. Two tiers
  bound the WAL: `checkpoint_threshold_bytes` and
  `checkpoint_interval_ms`. Syncs on a continuing segment resume mid-WAL
  from the last captured frame; only the first capture and post-restart
  syncs scan from the beginning.
- Restore requires the plan's first file to start at TXID 1 from the empty
  position; chains that begin mid-history need an earlier snapshot.
