# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html). While the major
version is zero, the Zig source API is intentionally unstable.

## [Unreleased]

## [0.1.0] - TBD

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
