# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0] - 2026-08-21

### Added

- Allocation-free LTX v3 decoding and canonical encoding for current raw-LZ4
  blocks and the historical upstream frame profile.
- Strict structure, page-index, CRC-64, rolling database, snapshot, and terminal
  verification over bounded caller-owned workspaces.
- Bounded storage-neutral compaction and staged apply orchestration.
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
- MIT licensing with the required separate BSD-3-Clause LZ4 and Apache-2.0
  Celld/Litestream attributions.

### Changed

- CI now qualifies Debug and ReleaseSafe behavior on pinned Linux and macOS
  toolchains, public-module compilation across five targets, consumer package
  wiring, the bounded example, and release metadata.
- A pinned, digest-locked `act` task rehearses the Linux lane without mounting
  the host Docker daemon; hosted Linux and macOS remain authoritative.
- SQLite directory durability barriers are portable across qualified hosts.
