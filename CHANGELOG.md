# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html). While the major
version is zero, the Zig source API is intentionally unstable.

## [Unreleased]

### Added

- `ltx_s3`: replace-if-generation lease renewal (`object_etag` plus
  `put_if_match` with `ETagMismatch` on a shifted generation), an optional
  caller-injected retry policy for transient transport failures and
  retryable statuses on idempotent requests, and virtual-host bucket
  addressing alongside path style.
- `ltx_capture`: a frame-count checkpoint tier (`checkpoint_max_frames`)
  alongside the byte and interval tiers, and `seed_position` for
  continuing a restored replica at the recovered TXID instead of
  restarting the numbering at one.
- A capture crash drill in `capture-integration`: kill a writer between
  durable batches, restore the tree to exactly the last reported batch,
  seed the position, and continue capture without history repair.
- An opt-in scale qualification tool (`zig build scale-check`) with
  measured capture, compaction, and restore throughput and byte-identical
  verification at hundreds of MiB; numbers recorded in
  `docs/replication.md`.
- CI runs the S3 MinIO gate on the macOS lane as well as Linux.
- `ltx_resources`, a shipped checked resource-planning module with the codec,
  WAL, apply, and wire formulas previously private to the benchmark harness,
  plus an alignment-aware fixed-arena binder for typed and byte workspaces.
- `ltx_object` transactional `WriteSession` support with explicit
  finish/abort publication semantics, implemented by the filesystem backend
  with private sync-and-rename staging.
- `ltx_replication`, a synchronous per-database controller for guarded startup,
  capture and position, restore, caller-selected adjacent-level maintenance,
  and publish-before-delete retention over caller-owned resources.
- Automatic S3 transactional publication: small encoded objects use one PUT,
  while larger outputs switch boundedly to multipart without retaining the
  complete object.
- `ltx_capture.Session.checkpoint_pending`, which exposes a deferred automatic
  PASSIVE-checkpoint retry without turning an already published capture into a
  failed sync.

### Changed

- The S3 conformance, TLS, and virtual-host lanes each run their own
  MinIO instance in the gate runner; manual `zig build s3-integration`
  without the runner skips the TLS and virtual-host lanes. The
  virtual-host lane runs on Linux only — some macOS CI runners do not
  resolve `*.localhost` to loopback — while plain and TLS lanes cover
  both platforms.
- Object listings now report exact `size_bytes`; compaction planning consumes
  that metadata directly instead of requiring parallel size arrays and
  redundant object reads.
- `ltx_replica.RestoreJob` accepts any `ltx.ApplyBackend`, verifies that each
  object key matches its decoded TXID range before staging, and safely replaces
  an existing target with the first snapshot before applying contiguous tails.
- S3 retry waiting is caller-injected alongside delay selection, and TLS
  certificate validation derives its time from the injected SigV4 clock; the
  module no longer reads an ambient clock.
- Capture and compaction stream encoder output directly through transactional
  object adapters; whole-object buffering remains as the compatibility path
  for adapters without write sessions.
- The portability compile gate now includes the external consumer so all nine
  public modules are checked on every hosted cross-target.
- The replication controller copies its compaction ladder, preflights encoder
  capacity and live workspace ranges, preserves readiness after caller-input
  errors, and requires sidecar-free quiescence for startup restore.

### Fixed

- S3 delete and multipart-abort teardown no longer wait for a keep-alive peer
  timeout after a bodyless `204 No Content` response.
- S3 `litestream-timestamp` metadata now uses Litestream-compatible UTC
  RFC3339Nano text instead of decimal Unix milliseconds.
- Filesystem object staging uses collision-safe exclusive names, synchronizes
  the complete directory chain, and reports post-rename sync failures as
  `PublicationIndeterminate` without removing the visible object.
- Capture handles empty and zero-commit WALs with a safe database snapshot,
  rejects truncated headers and aliased live workspaces, enforces frame-count
  checkpoints, and verifies PASSIVE completion before recording a restart.
- S3 multipart completion rejects HTTP-200 error XML, response reads remain
  bounded without `Content-Length`, conditional writes are never retried,
  failed aborts retain retryable cleanup state, listing pages are explicitly
  bounded, and every request refreshes TLS time from the injected clock.
- Controller retention deletes only the selected sources proven to be covered
  by the newly verified output; corrupt upper metadata cannot delete an
  unselected lower object.

## [0.3.0] - 2026-08-27

### Added

- `ltx_wal`: bounded SQLite WAL parsing with committed page maps, salt
  scans, torn-tail tolerance, and mid-WAL resume, ported from the pinned
  Celld crate with Go-ported known answers, a differential page-map
  reference, pinned Litestream WAL fixtures, a mutation suite, and a
  native fuzz corpus.
- LTX naming helpers in the core: TXID text, the filename codec, level
  names for both replica layouts, and Litestream-exact path joins.
- `ltx_object`: the storage-neutral object contract, the filesystem
  backend in the Litestream replica layout with atomic publication, and a
  backend-agnostic conformance suite.
- `ltx_s3`: the S3 backend with path-style SigV4, prefix-scoped paginated
  listings with `start-after` seek, object read/write/delete, bucket
  creation, signed conditional writes for first-writer fencing, TLS with
  a custom or system certificate authority, and part-streamed multipart
  upload. Gated against a local MinIO server over both plain HTTP and
  TLS, including the full conformance suite and multipart round trips.
- `ltx_replica`: the Litestream compaction ladder, restore planning with
  per-level cursors and tail-gap rejection, compaction and retention
  planning, restore-to-path and level-compaction executors over
  caller-owned workspaces, with exact restored-image end-to-end tests.
- `ltx_capture`: the SQLite capture session with Litestream control
  tables, a checkpoint-blocking read lock, snapshot/incremental
  transitions with mid-WAL resume, DB-file page backfill, snapshot
  fallback on foreign WAL discontinuity, no-checksum L0 publication, and
  two-tier passive checkpointing where session-initiated restarts
  continue with small incrementals. Integration-qualified against host
  SQLite by querying restored images read-only.
- Outbound Litestream v0.5.16 binary interop over a live `ltx_capture`
  tree: the pinned release binary restores the captured tree to a
  byte-identical image of the checkpointed database.
- A runnable one-shot replication-and-restore example as the consumer
  template, a replication deployment contract (`docs/replication.md`),
  and the replication roadmap with milestone status.
- Corrected the darwin-arm64 Litestream archive and `checksums.txt`
  SHA-256 pins in `docs/upstream.md` against the release manifest.

### Changed

- The core remains unchanged; the replication modules are additive and
  keep the core free of filesystem, SQLite, and libc linkage. Only
  `ltx_capture` declares a SQLite C surface that the host build links.
- `S3Client.init` returns an error union because TLS certificate
  loading can fail; pre-1.0 source instability applies.

## [0.2.0] - 2026-08-22

### Added

- Explicit LTX v2 import support for decoding, staged application, and
  crash-safe SQLite generation publication, anchored to `superfly/ltx` v0.4.0.
- Per-input format selection for bounded compaction so verified v2 and v3
  transitions can be migrated into one canonical v3 output.
- Independent current-Go byte qualification for v2-only, mixed v2/v3, and
  SQLite-image migrations into canonical v3.
- Structured v2/v3 apply and compactor fuzz corpora plus direct page-limit,
  checksum-operand, and SQLite generation-overflow coverage.

### Changed

- Format selection remains out of band because LTX v2 and v3 share the `LTX1`
  magic. The encoder remains v3-only; v1 remains unsupported.
- `CompactionInput.init` now requires the trusted out-of-band format version
  for every input; this is an intentional pre-1.0 source change.
- The aggregate fixture gate now reproduces all committed current-Go and v2
  oracle fixtures in addition to checking their reviewed hex mirrors.

## [0.1.0] - 2026-08-22

### Added

- Allocation-free LTX v3 decoding and canonical encoding for current raw-LZ4
  blocks and the historical upstream frame profile.
- Strict structure, page-index, CRC-64, rolling database, snapshot, and terminal
  verification over bounded caller-owned workspaces.
- Bounded storage-neutral compaction and staged apply orchestration.
- External path-dependency compile and smoke gates plus runnable bounded
  snapshot-apply and SQLite generation-store lifecycle examples.
- A canonical local source-archive smoke gate that extracts with isolated
  caches and runs the archived consumer and examples.
- Optional crash-qualified two-generation SQLite storage with typed read-only
  generation leases and explicit recovery after indeterminate publication.
- Real WAL-mode SQLite A-to-B-to-C qualification for checksummed snapshot and
  incremental publication, including growth, shrink, blocked reset and lease
  paths, late input corruption, exact generation bytes, and semantic queries.
- SQLite-produced A-to-B-to-C process-crash replay at every publication
  durability boundary, plus retained-lease, stale-epoch, and checksum-scanning
  recovery qualification over real database images.
- Pinned Go and Celld interoperability fixtures, mutation and fuzz suites, and
  byte-for-byte Go-oracle compaction checks.
- An immutable real-Litestream v0.5.11 six-transition capture chain with exact
  artifact and restored-image hashes plus final read-only SQLite qualification.
- Outbound compaction qualification against pinned Go bytes and a
  checksum-pinned Litestream v0.5.16 restore over mixed current-L1 and
  legacy-L0 page representations.
- A five-chain deterministic compaction matrix with exact Go output bytes,
  pinned database hashes, staged-apply equivalence, and real-Litestream
  success/expected-rejection coverage of its no-checksum restore boundary.
- Public SQLite store state and adapter-specific failure inspection, with an
  explicit retry/recovery decision contract.
- Exhaustive returned-fault qualification at every SQLite durability boundary
  and synchronized cross-process generation-lease abandonment coverage.
- MIT licensing with the required separate BSD-3-Clause LZ4 and Apache-2.0
  Celld/Litestream attributions.
- A checked resource-budget model with conservative workspace/output formulas,
  reference configurations, and portable formula tests.
- A 17-case encoder/decoder 4 KiB–64 KiB pattern matrix, 1/4/16-input
  compaction scaling, checked/no-checksum staged-apply benchmarks, and a
  correctness-only smoke mode; the focused raw-LZ4 microbenchmark remains
  available separately.

### Fixed

- SQLite generation workspace alias failures now report
  `Failure.invalid_workspace` instead of `Failure.invalid_state`.

### Changed

- The pre-1.0 Zig source API is explicitly allowed to evolve with its
  coordinated consumer; 0.x releases make no source-compatibility promise.
- CI now qualifies Debug and ReleaseSafe behavior on pinned Linux and macOS
  toolchains, public-module compilation across five targets, consumer package
  wiring, the bounded example, and release metadata.
- A pinned, digest-locked `act` task rehearses the Linux lane without mounting
  the host Docker daemon; hosted Linux and macOS remain authoritative.
- SQLite directory durability barriers are portable across qualified hosts.
- Release metadata validation permits `TBD` during candidate work but requires
  a real `YYYY-MM-DD` changelog date before tag qualification.
- CI compiles both benchmark executables and runs resource and benchmark-smoke
  correctness gates without timing thresholds.
