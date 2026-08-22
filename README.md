# ltx-zig

`ltx-zig` is an embeddable, allocation-free codec, bounded compactor, and staged
apply orchestrator for Lite Transaction (LTX) files. LTX records a verified
transition between two SQLite replication positions:

```text
position before + verified LTX transition = position after
```

The project follows a safety-first interpretation of TigerStyle: all work and
memory are explicitly bounded, wire integers are decoded field by field, and
unverified pages never masquerade as an authoritative database state. The
package is named `ltx-zig`; consumers import its public module as `ltx`.

## Status

This checkpoint supports the current and historical LTX v3 page encodings
emitted by `superfly/ltx` at the revisions pinned in
[docs/upstream.md](docs/upstream.md). The pinned `denoland/celld` LTX crate is
also used as a secondary format and deployment reference:

- explicit `.v3` selection on every decoder and encoder;
- current six-byte page headers with `PageHeaderFlagSize`;
- independent raw LZ4 blocks, including normal match-compressed Go output;
- canonical legacy unflagged LZ4 frames, including compressed and stored blocks;
- a deterministic, byte-compatible raw LZ4 match compressor with bounded
  caller-owned state;
- streaming page events over caller-defined transports;
- bounded, caller-owned page, compressed-data, LZ4 match-state, and page-index
  workspaces;
- canonical page-index emission and strict index cross-checking;
- CRC-64/ISO page, rolling database, and logical file checksums;
- snapshots, incrementals, no-checksum transitions, and empty databases;
- strict terminal verification and trailing-byte rejection;
- allocation-free, oldest-to-newest compaction with exact TXID and
  enabled-checksum continuity, latest-page precedence, and final-commit
  truncation;
- storage-neutral private staging with explicit contiguous and snapshot-replace
  modes;
- a full staged-image checksum pass and one atomic backend publication boundary;
- an optional allocation-free `ltx_sqlite` filesystem store with quiescent
  connection lifecycle hooks, two immutable database generations, a
  checksummed atomic manifest with a durable empty baseline, sidecar rejection,
  durability barriers, and explicit recovery after an indeterminate commit.

The decoder covers both page encodings emitted across upstream v3 history. The
encoder always emits the current flagged raw-block representation. Valid LZ4
frame profiles that upstream LTX never emitted remain deliberately unsupported.
LTX v2 and fixed-path replacement beneath live SQLite connections are not
implemented. Compaction is a codec-level merge: it does not select storage
levels, delete source files, publish a replica, or manage a Litestream process.
The core API remains synchronous, transport-neutral, and free of filesystem and
SQLite dependencies. See [docs/compaction.md](docs/compaction.md) for its exact
contract. The optional store is deliberately a quiescent replica/apply
destination: the host drains SQLite through an application-owned lifecycle
gate, and published generation paths may be opened only under a generation
lease using SQLite URI `mode=ro&immutable=1` and `query_only`. It does not link
a second SQLite copy or manage application connection handles itself. See
[docs/sqlite-store.md](docs/sqlite-store.md).

`ltx-zig` is licensed under the [MIT License](LICENSE). The fast-compressor
algorithm includes BSD-3-Clause-licensed work whose separate notice is retained
in [`LICENSE.pierrec-lz4`](LICENSE.pierrec-lz4). Distributions must retain the
applicable notices.

## Toolchain and tests

Zig 0.16.0 is pinned by `.mise.toml`; `build.zig.zon` also rejects older Zig
versions through its minimum-version field.

```sh
mise exec -- zig version
mise exec -- zig build
mise exec -- zig build fmt-check
mise exec -- zig build test
mise exec -- zig build sqlite-integration # optional; links the host libsqlite3
mise exec -- zig build fuzz -Doptimize=ReleaseSafe # replay fuzz corpora
mise exec -- zig build fuzz --fuzz=10K -Doptimize=ReleaseSafe --seed 0
mise exec -- zig build interop # optional; requires Go and may download modules
mise exec -- zig build bench   # optional local compression benchmark
```

Generate a deterministic v3 file on standard output with:

```sh
mise exec -- zig build fixturegen > /tmp/ltx-zig.ltx
```

Generate any deterministic multi-input compaction case with:

```sh
mise exec -- zig build compaction-fixture -Dcompaction-fixture=merge > /tmp/ltx-merge.ltx
mise exec -- zig build compaction-fixture -Dcompaction-fixture=deletion > /tmp/ltx-deletion.ltx
mise exec -- zig build compaction-fixture -Dcompaction-fixture=no-checksum > /tmp/ltx-no-checksum.ltx
```

Regenerate one of the pinned Go corpus files on standard output with:

```sh
mise exec -- zig build upstream-fixture -Dfixture=near-lock > /tmp/go-near-lock.ltx
```

Regenerate a historical unflagged-frame fixture with:

```sh
mise exec -- zig build upstream-legacy-fixture -Dlegacy-fixture=mixed > /tmp/go-legacy.ltx
```

After reviewing fixture hex mirrors, materialize or non-destructively check the
committed binaries with:

```sh
mise exec -- zig build materialize-fixtures
mise exec -- zig build check-fixtures
mise exec -- zig build check-legacy-fixtures
```

The hermetic test suite includes byte-exact fixtures generated by the pinned Go
implementation and the pinned Celld tree. The optional `interop` step verifies
a fresh Zig snapshot with the exact pinned Go decoder. It also independently
constructs checked merge and deletion inputs plus a no-checksum chain in Go,
runs the pinned Go compactor, byte-compares its outputs with fresh Zig
compaction outputs, and decodes them again with Go. Normal tests stay
network-free, replay the checked-in fuzz corpora, and run a deterministic
mutation suite; [docs/fuzzing.md](docs/fuzzing.md) documents the bounded native
fuzz run used in CI and longer local sessions.

## Encoding workspace

In addition to compressed-output and page-index storage, each encoder receives
one fixed `LZ4CompressionWorkspace` by pointer. It occupies 139,264 bytes
(136 KiB), may begin undefined, and resets its occupancy bitmap before any
match-state read:

```zig
var compressed_workspace: [66_000]u8 = undefined;
var lz4_workspace: ltx.LZ4CompressionWorkspace = undefined;
var index_workspace: [4096]ltx.PageIndexEntry = undefined;
var encoder = try ltx.Encoder.init(
    .v3,
    limits,
    sink.writer(),
    &compressed_workspace,
    &lz4_workspace,
    &index_workspace,
);
```

For an `n`-byte page, an output cap of `n + n / 255 + 16` enables the exact
fast compressor used by the pinned Go and Celld implementations. A smaller cap
is still valid when it can hold the literal encoding; the encoder then uses
that deterministic bounded fallback. At the maximum SQLite page size, those
caps are 65,809 and 65,794 bytes respectively.

## Minimal decoding example

The decoder receives an explicit format version, explicit limits, a transport,
and all variable-size workspace during initialization. Page data is explicitly
unverified and is overwritten by the next decoder operation.

```zig
const ltx = @import("ltx");

const limits = ltx.Limits{
    .max_input_bytes = 16 * 1024 * 1024,
    .max_output_bytes = 16 * 1024 * 1024,
    .max_pages = 4096,
    .max_page_size = 65_536,
    .max_compressed_page_size = 66_000,
    .max_page_index_bytes = 128 * 1024,
    .max_page_index_entries = 4096,
    .max_varint_bytes = 10,
    .max_transaction_span = 4096,
};

var source = ltx.SliceReader.init(file_bytes);
var page_workspace: [65_536]u8 = undefined;
var compressed_workspace: [66_000]u8 = undefined;
var index_workspace: [4096]ltx.PageIndexEntry = undefined;
var decoder = try ltx.Decoder.init(
    .v3,
    limits,
    source.reader(),
    &page_workspace,
    &compressed_workspace,
    &index_workspace,
);

var event_count: u64 = 0;
while (event_count < decoder.event_budget()) : (event_count += 1) {
    switch (try decoder.next()) {
        .header => |header| _ = header,
        .unverified_page => |page| {
            // Stage page.data; do not publish it yet.
            _ = page;
        },
        .page_block_complete => {},
        .verified => |verified| {
            // Only now may staged pages be committed atomically.
            _ = verified;
            break;
        },
    }
}
```

See [docs/design.md](docs/design.md) for trust, memory, and state-machine
details, [docs/compaction.md](docs/compaction.md) for the bounded merge API,
[docs/apply.md](docs/apply.md) for the storage backend contract, and
[docs/compatibility.md](docs/compatibility.md) for the exact feature matrix.

## Quiescent SQLite store

Consumers that need durable filesystem publication can also import the optional
module as `ltx_sqlite`. Its `Store` borrows a `std.Io.Dir`, a non-empty
caller-owned copy/checksum workspace, and a `Lifecycle` callback pair. The
quiesce callback must stop new SQLite opens, checkpoint and close all owned
connections, and leave both generation names without `-wal`, `-shm`, or
`-journal` files. Active connections use an encoded SQLite URI with
`mode=ro&immutable=1` while holding the generation lease. `store.backend()`
plugs directly into `StagedApplier`.
`store.recover()` on a pristine directory durably creates the empty baseline;
the first snapshot also initializes it automatically before creating a database
slot. Interrupted first stages recover back to empty without guessing.

After a successful apply, `store.current()` returns the manifest-bound position,
page size, exact length, generation, and database filename. If apply returns
`error.ApplyPublishIndeterminate`, the store deliberately keeps the lifecycle
gate closed; call `store.recover()` until it succeeds before opening SQLite or
starting another apply. Full deployment constraints and crash outcomes are in
[the SQLite store guide](docs/sqlite-store.md).

Store changes are qualified with real child-process termination at every
baseline and publication sync/rename boundary. `zig build sqlite-integration`
additionally exercises the host SQLite library's WAL drain, read-only generation
access, data queries, and `PRAGMA integrity_check` without linking SQLite into
either library module.
