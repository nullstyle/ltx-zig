# Replication roadmap

This roadmap extends `ltx-zig` from an LTX codec toolkit into a SQLite-to-S3
replication library: the same capability set as the pinned `denoland/celld` LTX
crate, exposed as an embeddable library rather than a daemon. The consumer
built above this library — for example, a stateful actor system giving each
actor its own SQLite database — owns orchestration: which databases exist, when
to sync, how migrations are fenced, and how work is scheduled. The library owns
format knowledge, SQLite lifecycle, object transport, and the replication
engine.

## Scope boundary

In scope (library):

- SQLite WAL parsing, capture lifecycle, checkpoint policy, and LTX emission.
- Object transport to S3-compatible stores and the local filesystem.
- The replica engine: sync, position derivation, restore planning, compaction
  levels, and retention.
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
| `ltx_capture` (M2) | `db.rs` | The SQLite system: WAL-mode open, `_litestream_seq`/`_litestream_lock` control tables, the long-running read lock, the `verify` continuity brain (WAL truncation, the `WALOffset == 32` edge, salt-mismatch branches, checkpoint restart), snapshot and incremental collection with database-file fallback and grown pages, the three-tier checkpoint policy with writer barrier, and atomic L0 publication. |
| `ltx_object`, `ltx_s3` (M3) | `client/*` | The object-client contract (`ltx_files`, `open_ltx_file`, `write_ltx_file`, `delete_ltx_files`, capability flags including conditional PUT), a filesystem backend whose conformance suite runs hermetically, and the S3 implementation: SigV4 over the standard library HTTP client, bounded iterative `ListObjectsV2` XML parsing, single PUT from a workspace buffer, fixed-part multipart for snapshots, batch delete, bounded retry, and `litestream-timestamp` metadata. |
| `ltx_replica` (M4) | `replica.rs`, `replica_compactor.rs`, `compaction_level.rs` | The sync loop and position seeding and derivation (including the skip-listing seeded-position path), restore planning and restore-to-path through `StagedApplier`, the level ladder (L0/L1/L2/L3 plus snapshot level 9), additive level compaction over the existing `Compactor`, and retention as bounded batch deletes. |
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
- **SQLite linkage lives in `ltx_capture`.** This amends the current rule that
  confines SQLite to integration tests: `ltx_capture` may link the host system
  SQLite through a build option, using the same pattern as
  `sqlite-integration`. The binding is a hand-written minimal C surface with
  explicit error mapping. The `ltx` core and `ltx_sqlite` store remain
  libc-free and SQLite-free.
- **Injected credentials and configuration.** The S3 client takes credentials,
  region, and endpoint from caller-provided values or a refresh callback. No
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
| M2 — `ltx_capture` ◐ | Hand-written SQLite C surface; WAL-mode session with Litestream control tables and a checkpoint-blocking read lock; first-capture snapshots, salt-and-offset incremental extension, checkpoint-restart snapshot fallback, DB-file page backfill, no-checksum L0 publication through `ltx_object`; passive checkpointing with a byte threshold and control-row forcing, where a session-initiated checkpoint continues with small incrementals; mid-WAL resume so continuing segments scan only new frames with a seeded checksum chain. Remaining: the multi-tier checkpoint policy with writer barrier and crash-replay qualification. Litestream v0.5.16 binary interop over captured trees is verified by `litestream-interop`: the release binary restores a `ltx_capture` tree (snapshot, incremental, post-checkpoint incremental) to a byte-identical image of the live database. | `capture-integration` against host SQLite: snapshot/incremental/post-checkpoint capture, bounded-WAL growth, foreign-restart fallback, and restores verified by read-only SQLite queries. |
| M3 — `ltx_object`/`ltx_s3` ✅ | Backend-agnostic `Client` contract with a conformance suite, the filesystem backend in the Litestream layout, and the S3 backend: path-style SigV4 over the standard-library HTTP client with an injected clock, paginated `ListObjectsV2` scoped by level prefix with `start-after` seek, `GetObject`, single-request `PutObject` with the `litestream-timestamp` metadata header, per-object `DeleteObject`, bucket creation, and signed conditional writes (`put_if_absent`, first writer wins) for host-side fencing. Multipart upload (part-streamed, single in-flight per client) and TLS with custom or system CA verification are included; virtual-host addressing remains a follow-up. | Hermetic filesystem conformance suite; `mise run s3-integration` runs the same suite plus a plan round trip against a local MinIO server started by `tools/s3_gate/run.sh`. |
| M4 — `ltx_replica` ✅ | Level ladder, `calc_restore_plan`, compaction and retention planners, restore-to-path through `StagedApplier`, level compaction through `Compactor`, core naming helpers (`FileInfo`, filename codec, level layouts, TXID text). | Planner truth tables ported from Celld; end-to-end encode → store → plan → restore → compact → retain tests with exact-image verification. |
| M5 — consolidation ✅ | This roadmap, `AGENTS.md` amendments, upstream evidence, resource budgets, the `replicate-once` consumer template, and [`replication.md`](replication.md) as the deployment contract. CI matrix updates ride along with the next release. | `fmt-check`, `test`, `resource-check`, `fuzz`, `capture-integration`, `s3-integration`, `consumer-smoke`. |

Normal tests stay network-free throughout. The S3/MinIO and Litestream-binary
interop gates remain opt-in once their implementations land.

## Estimate

Roughly 8–10.5k lines of Zig including tests across M1–M5, about doubling the
repository. M1 alone is approximately 1.2–1.5k lines with fixtures, mutation
tests, and fuzz corpora.
