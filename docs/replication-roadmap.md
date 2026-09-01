# Replication roadmap

This roadmap records the completed extension of `ltx-zig` from an LTX codec
toolkit into bounded SQLite-to-object-store replication building blocks,
informed by the pinned `denoland/celld` LTX crate and exposed as an embeddable
library rather than a daemon. The M1–M11 stack is shipped: the original
foundations, a public checked resource binder, transactional object writes,
bounded object reads, a synchronous per-database controller, and deterministic
qualification of interrupted maintenance and multipart publication. The
controller's descriptor and complete workspace set can now be derived and
bound from one fixed caller-owned arena, and its single owner can poll bounded
operation diagnostics without adding a logging or synchronization seam.
Sequential object reads additionally bind every refill to the backend
generation selected by their first successful range.

The consumer built above this library — for example, a stateful actor system
giving each actor its own SQLite database — owns which databases exist, when
work is scheduled, and how migrations are fenced. The library owns format
knowledge, SQLite capture lifecycle, object transport, and the bounded
replication planners and executors.

## Scope boundary

In scope (library):

- SQLite WAL parsing, capture lifecycle, checkpoint policy, and LTX emission.
- Object transport to S3-compatible stores and the local filesystem.
- Replication primitives and orchestration: restore planning and execution,
  compaction levels and execution, retention planning, position derivation,
  and a synchronous controller.
- All existing codec, compaction, staged-apply, and quiescent-store behavior.

Out of scope (consumer):

- Actor-to-database mapping and lifecycle, scheduling, and concurrency.
- Workspace pooling across many databases.
- Lease and fencing policy (the S3 client exposes conditional PUT so a
  consumer can build fencing; the library never dictates migration policy).
- Durability and acknowledgement policy. The engine can capture per committed
  transaction; whether every write blocks on the upload is the consumer's
  decision.
- Observability plumbing beyond bounded counters the consumer polls.

## Module map

| Module | Ports from celld | Contents |
| --- | --- | --- |
| `ltx_wal` (M1) | `wal.rs` | WAL header/frame parsing, salts, cumulative checksum chains, committed page map (bitmap plus entries, newest-wins, caller-owned), salt census for checkpoint detection, torn-tail tolerance, and mid-WAL resume seeding. |
| `ltx_capture` (M2) | `db.rs` | WAL-mode open, `_litestream_seq`/`_litestream_lock` control tables, a checkpoint-blocking read lock, snapshot and incremental collection with database-file fallback and grown pages, foreign-discontinuity snapshot fallback, seeded continuation after restore, mid-WAL resume, three-tier passive checkpoint policy, and atomic L0 publication. The Celld writer barrier is intentionally omitted for the single-writer-per-database model. |
| `ltx_object`, `ltx_s3` (M3/M6/M7/M11) | `client/*` | The object-client contract and filesystem backend plus S3-compatible path-style and virtual-host SigV4, bounded paginated `ListObjectsV2`, exact generation-bound ranged reads with bounded sequential reader windows, idempotent per-object deletes, conditional create/replace, TLS, bounded retry, `litestream-timestamp` metadata, and transactional writer sessions that publish through filesystem staging or automatic single/multipart upload. |
| `ltx_replica` (M4) | `replica.rs`, `replica_compactor.rs`, `compaction_level.rs` | Restore planning and generic staged-apply execution, the level ladder (L0/L1/L2/L3 plus snapshot level 9), bounded level compaction over the existing `Compactor`, and retention planning. |
| `ltx_resources` (M6) | — | Checked public codec, apply, WAL, and wire capacity formulas plus an alignment-aware fixed-arena binder. |
| `ltx_replication` (M6/M9/M10) | `replica.rs`, `db.rs` | One synchronous controller for empty, verified-local, or restore-latest startup; complete fixed-arena resource derivation and binding; capture and trusted position; all-level restore; caller-selected adjacent-level compaction; publish-before-delete retention; and copied, allocation-free operation diagnostics. Scheduling, fencing, acknowledgement, and telemetry export stay outside. |
| core additions (M4) | `lib.rs` | `FileInfo`, filename formatting and parsing, `TXID` text parsing, and level-directory naming for both the decimal filesystem layout and the four-hex object-store layout. |

The `ltx` core and the `ltx_sqlite` store are unchanged by this roadmap. The
store remains the read-only-serving option; restore-to-path needs only
`StagedApplier` with a filesystem backend.

## Design decisions

- **Synchronous, explicit-time APIs.** No async runtime and no ambient clock.
  Operations take timestamps and block; the consumer's scheduler provides
  concurrency across databases.
- **Current flagged blocks only.** All new output uses the canonical current
  v3 representation. This is a greenfield writer: writer and reader are this
  library, with Litestream v0.5.16 retained as the emergency restore oracle.
- **Byte-compatible object layout.** Object keys and metadata follow the
  pinned Celld and Litestream layouts exactly, so external tools keep working
  and the `litestream-interop` gate can cover full replica trees.
- **Exact continuity.** Everywhere the library makes a decision — compaction,
  restore-plan tail checks — TXID ranges must join exactly and enabled
  checksums must match. Compaction is never implicit history repair.
- **SQLite declarations live in `ltx_capture`.** The module owns a hand-written
  minimal C surface with explicit error mapping, but no library module links
  SQLite or libc. The host executable supplies that linkage, using the same
  pattern as `capture-integration`. The `ltx` core and `ltx_sqlite` store remain
  libc-free and SQLite-free.
- **Injected credentials and configuration.** The S3 client takes credentials,
  region, endpoint, clock, and retry timing from caller-provided values. No
  instance-metadata service and no ambient environment reads inside the
  library.

## Resource model

Every new module keeps the existing discipline: no allocation after
initialization, caller-owned fixed-capacity workspaces, explicit limits
validated before bytes are consumed, checked offset and length arithmetic, and
bounded loops. `docs/resource-budgets.md` grows a formula section per module,
and `resource-check` verifies them.

## Milestones and gates

| Milestone | Ships | Gates |
| --- | --- | --- |
| M1 — `ltx_wal` ✅ | WAL parser, pinned fixtures (the Celld sample WAL and the Go WAL testdata) | Mutation suite, checked-in fuzz corpora, `zig build fuzz`, `resource-check` formulas. |
| M2 — `ltx_capture` ✅ | Hand-written SQLite C surface; WAL-mode session with Litestream control tables and a checkpoint-blocking read lock; first-capture snapshots, salt-and-offset incrementals, DB-file page backfill, foreign-restart snapshot fallback, no-checksum L0 publication, seeded continuation after restore, and mid-WAL resume. Byte, age, and frame-count thresholds drive passive checkpoints; a session-initiated restart continues with small incrementals. A process crash drill restores the last reported batch, seeds it, and continues without repair. Litestream v0.5.16 restores a live captured tree to a byte-identical image. The Celld writer barrier is deliberately absent because this module owns the single writer for its database. | `capture-integration` in Debug and ReleaseSafe against host SQLite: snapshot/incremental/post-checkpoint capture, all checkpoint tiers, bounded-WAL growth, foreign-restart fallback, process-crash continuation, and restores verified by read-only SQLite queries. |
| M3 — `ltx_object`/`ltx_s3` ✅ | Backend-agnostic `Client` contract with a conformance suite, the filesystem backend in the Litestream layout, and the S3 backend with an injected SigV4 clock, path-style and virtual-host addressing, paginated level-scoped listings, object reads/writes/deletes, bucket creation, conditional create and ETag-matched replacement, TLS with custom or system CA verification, bounded idempotent-request retry, and single-in-flight part-streamed multipart upload. | Hermetic filesystem conformance suite; `mise run s3-integration` starts isolated pinned MinIO instances for plain HTTP, TLS, and the supported virtual-host lane, then runs conformance, planning, conditional-write, retry, and multipart coverage. |
| M4 — `ltx_replica` ✅ | Level ladder, `calc_restore_plan`, compaction and retention planners, restore-to-path through `StagedApplier`, level compaction through `Compactor`, core naming helpers (`FileInfo`, filename codec, level layouts, TXID text). | Planner truth tables ported from Celld; end-to-end encode → store → plan → restore → compact → retain tests with exact-image verification. |
| M5 — consolidation ✅ | This roadmap, engineering rules, upstream evidence, resource budgets, the `replicate-once` consumer template, and [`replication.md`](replication.md) as the deployment contract. | `fmt-check`, `test`, `resource-check`, `fuzz`, `capture-integration`, `s3-integration`, `consumer-smoke`, Litestream interoperability, and canonical source-archive qualification. |
| M6 — orchestration and bounded publication ✅ | Public resource formulas and fixed-arena binding; exact object sizes; generic identity-checked restore; transactional filesystem and S3 writer sessions; direct capture/compaction publication; and the `ltx_replication.Controller`. | Hermetic session and planner tests, live SQLite controller lifecycle, zero-output-buffer capture, automatic MinIO single/multipart publication, scale qualification, consumer wiring, and release gates. |
| M7 — bounded object reads ✅ | Exact range reads in the object contract; an allocation-free sequential `ObjectReader` poisoned by range failures; filesystem positional reads; signed S3 single-range GETs with exact `Content-Range` validation; and restore/compaction input windows sized independently of the accepted object limit. | Backend conformance and malformed-range tests, MinIO range qualification, tiny-window restore and interleaved compaction, controller capacity and alias checks, scale qualification, and release gates. |
| M8 — deterministic interruption hardening ✅ | Restart-safe controller retention reconciliation that re-verifies the covering upper-level restore plan before source or covered-snapshot deletion; precise S3 transactional publication uncertainty as `PublicationIndeterminate`; and fixed, deterministic fault checkpoints at the existing object and HTTP seams rather than a new production fault API. | Hermetic controller restart tests cover interruption before and during source and older-snapshot cleanup and require an exact restored image; scripted S3 tests cover single PUT, multipart initiation, part upload, completion acknowledgement loss, abort failure, and cleanup retry, with the MinIO gate retaining real-protocol coverage. |
| M9 — complete controller arena ✅ | `Resources.arena_capacity_bytes` derives the complete checked budget for a configuration and client capability; `Resources.bind` places the descriptor and all controller workspaces in one caller-owned arena while preserving manual construction. Transactional adapters omit whole-object fallback storage. | Exact-capacity and one-byte-short arenas, hostile starting alignment, overflow and invalid configuration, transactional and whole-object client paths, manual-resource compatibility, the simplified consumer example, and the existing controller lifecycle gates. |
| M10 — bounded controller diagnostics ✅ | `Controller.diagnostics()` returns one infallible, pointer-free snapshot with ready/poisoned/finished lifecycle; saturating accepted/rejected/succeeded/failed counters for sync, restore, and maintenance; sticky saturation; and the exact last accepted result or error. Rejections preserve the causal accepted failure, and polling remains safe after poison and finish. No callback, clock, reset, history, scheduling policy, or allocation is added. | Hermetic lifecycle tests cover initial state, each operation's success path, preflight and terminal-state rejection, non-poisoning and poisoning accepted failures, cause preservation through rejection and finish, plus the counter saturation boundary. The consumer example polls the final snapshot, and the existing controller lifecycle and release gates remain authoritative. |
| M11 — generation-bound object reads ✅ | Every nonempty range returns one bounded, opaque generation receipt. `ObjectReader` carries the first receipt across refills while ordinary one-shot reads remain source-compatible. File reads compare explicit opened-handle identity before and after positional I/O; S3 binds the first response ETag and signs later ranges with `If-Match`. Mismatch poisons the reader as `ObjectChanged`; full LTX verification remains authoritative. | Receipt boundary and reader-poison tests, adversarial equal-length replacement, interleaved-reader independence, filesystem rename/in-place mutation, scripted S3 ETag and conditional-range failures, real MinIO replacement, scale qualification, and the existing release gates. |

Normal tests stay network-free. The dedicated S3/MinIO gate and
Litestream-binary interoperability gate are implemented and run in hosted CI;
their external tools remain outside the hermetic unit-test step.

## Candidate next increment

No post-M11 feature sprint is committed. The next increment should be chosen
after the generation-bound read contract has completed its full local CI,
MinIO, scale, and source-archive qualification; the pre-1.0 API remains free
to change as deployment evidence accumulates.
