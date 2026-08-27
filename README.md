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

This checkpoint supports importing LTX v2 and the current and historical LTX
v3 page encodings emitted by `superfly/ltx` at the revisions pinned in
[docs/upstream.md](docs/upstream.md). The pinned `denoland/celld` LTX crate is
also used as a secondary v3 format and deployment reference; it does not
provide a v2 oracle:

- explicit `.v2` or `.v3` decoder selection because both versions use the same
  `LTX1` magic;
- LTX v2 four-byte page headers and independent LZ4-frame pages for bounded
  import, staged apply, and migration;
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
- an immutable six-file L0 chain captured by real Litestream v0.5.11, verified
  prefix by prefix against exact restored SQLite image hashes;
- strict terminal verification and trailing-byte rejection;
- allocation-free, oldest-to-newest compaction with a version selected for
  each input, exact TXID and enabled-checksum continuity, latest-page
  precedence, final-commit truncation, and canonical v3 output;
- outbound compaction qualification in which pinned Go byte-matches a Zig L1
  prefix and Litestream v0.5.16 restores it together with a legacy L0 tail;
- a deterministic five-chain compaction matrix spanning checksummed growth,
  sparse shrink, maximum-page no-checksum shrink, checked deletion, and a
  legacy-to-current transition, with pinned Go bytes and database hashes;
- storage-neutral private staging with explicit contiguous and snapshot-replace
  modes;
- a full staged-image checksum pass and one atomic backend publication boundary;
- an optional allocation-free `ltx_sqlite` filesystem store with quiescent
  connection lifecycle hooks, typed shared generation access, two immutable
  database generations, a checksummed atomic manifest with a durable empty
  baseline, sidecar rejection, durability barriers, and explicit recovery after
  an indeterminate commit, qualified with real checksummed snapshot and
  incremental SQLite generations that grow and shrink.

The decoder covers the pinned v2 import profile and both page encodings emitted
across upstream v3 history. The encoder remains v3-only and always emits the
current flagged raw-block representation; v2 is an import and migration format,
not a new output option. Valid LZ4 frame profiles that upstream LTX never
emitted remain deliberately unsupported. LTX v1 and fixed-path replacement
beneath live SQLite connections are not implemented. Compaction is a
codec-level merge: it does not select storage
levels, delete source files, publish a replica, or manage a Litestream process.
The core API remains synchronous, transport-neutral, and free of filesystem and
SQLite dependencies. See [docs/compaction.md](docs/compaction.md) for its exact
contract. The [current API and stability policy](docs/api.md) explicitly keeps
the pre-1.0 Zig source surface free to evolve. The optional store is
deliberately a quiescent replica/apply destination: the host drains SQLite
through an application-owned lifecycle gate, and published generation paths
may be opened only under a generation access lease using SQLite URI
`mode=ro&immutable=1` and `query_only`. The lease holds a shared store lock from
manifest resolution until the host has closed every SQLite handle using that
URI. It does not link a second SQLite copy or manage application connection
handles itself. See [docs/sqlite-store.md](docs/sqlite-store.md).

`ltx-zig` is licensed under the [MIT License](LICENSE). The fast-compressor
algorithm includes BSD-3-Clause-licensed work whose separate notice is retained
in [`LICENSE.pierrec-lz4`](LICENSE.pierrec-lz4). The copied Celld/Litestream
capture corpus is Apache-2.0-licensed; its notice is retained in
[`LICENSE.celld-litestream-apache-2.0`](LICENSE.celld-litestream-apache-2.0).
Distributions must retain the applicable notices.

`ltx-zig` is pre-1.0. Its Zig source API may change in any 0.x release without
a compatibility shim or deprecation period. Development is coordinated with
one consumer; other users should pin an exact tag or commit. Wire compatibility
and the verification invariants above remain separately governed by explicit
version selection, the pinned oracles, and the interoperability suites.

## Using the package

For a tagged release, add the package to a consumer's `build.zig.zon` with:

```sh
zig fetch --save=ltx_zig https://github.com/nullstyle/ltx-zig/archive/refs/tags/v0.3.0.tar.gz
```

Then expose either or both public modules to the consumer root module:

```zig
const ltx_zig = b.dependency("ltx_zig", .{
    .target = target,
    .optimize = optimize,
});
const app = b.addExecutable(.{
    .name = "replica",
    .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "ltx", .module = ltx_zig.module("ltx") },
            .{ .name = "ltx_sqlite", .module = ltx_zig.module("ltx_sqlite") },
        },
    }),
});
b.installArtifact(app);
```

The `consumer-smoke` build step tests the same dependency and module wiring
through a local path dependency rather than importing modules directly from the
repository build. `consumer-compile` compiles that current external consumer
without running it; it is a regression check, not a compatibility promise.
`source-archive-smoke` creates the canonical local `zig fetch` tarball,
extracts it into a temporary tree, and uses isolated local and global caches to
run the archived external consumer and all shipped examples. That gate catches
missing package paths without consulting the live checkout or an existing
cache.

## Toolchain and tests

Zig 0.16.0 and the Go 1.24.13 fixture-oracle toolchain are pinned by
`.mise.toml`; `build.zig.zon` also rejects older Zig versions through its
minimum-version field. Setting `GOTOOLCHAIN=local` keeps oracle checks on that
exact Go toolchain instead of permitting an implicit download. The local CI
task pins `act` 0.2.89 without installing it on hosted CI runners.

```sh
mise exec -- zig version
mise exec -- zig build
mise exec -- zig build fmt-check
mise exec -- zig build test
mise exec -- zig build sqlite-integration # optional; links the host libsqlite3
mise exec -- zig build consumer-smoke
mise exec -- zig build consumer-compile
mise exec -- zig build example-round-trip
mise exec -- zig build example-apply-snapshot
mise exec -- zig build example-sqlite-store
mise exec -- zig build source-archive-smoke
mise exec -- zig build release-check
mise exec -- zig build resource-check
mise exec -- zig build bench-compile -Dbench-optimize=ReleaseSafe
mise exec -- zig build benchmark-smoke -Dbench-optimize=ReleaseSafe
mise exec -- zig build fuzz -Doptimize=ReleaseSafe # replay fuzz corpora
mise exec -- zig build fuzz --fuzz=10K -Doptimize=ReleaseSafe --seed 0
mise exec -- zig build interop # optional; requires Go and may download modules
mise exec -- zig build litestream-interop -Dlitestream=/absolute/path/to/litestream
mise exec -- zig build bench # optional core benchmark; ReleaseFast by default
mise exec -- zig build bench-lz4 # optional raw-LZ4 microbenchmark
```

With Docker running, the pinned `act` task parses and executes the exact Linux
job from `.github/workflows/ci.yml`:

```sh
mise run ci-local -- --dryrun
mise run ci-local
```

`.actrc` selects only `ubuntu-24.04`, forces the hosted runner's `linux/amd64`
architecture, pins the container image by digest, and does not mount the host
Docker daemon into the job container. Run it only from a trusted, reviewed
worktree. The first full run is a substantial download and needs outbound
access. No secrets are needed for this public read-only workflow; if GitHub
rate limits a run, use `mise run ci-local -- -s GITHUB_TOKEN` and enter a
least-privilege token at the secure prompt. Workflow code receives any supplied
token, so never use this fallback on an untrusted branch or store tokens in
`.actrc`. `act` cannot qualify the hosted macOS lane and its runner image is an
approximation. The local lane deterministically replays the fuzz corpora;
hosted native Linux performs the 10K instrumented search. The complete GitHub
matrix therefore remains mandatory. See
[the release checklist](docs/releasing.md) for the full gate.

The runnable [`examples/round_trip.zig`](examples/round_trip.zig) encodes and
decodes a one-page snapshot using only bounded stack storage.
[`examples/apply_snapshot.zig`](examples/apply_snapshot.zig) carries that
snapshot through private staging and atomic publication in a fixed-capacity
single-owner memory backend. Its callback has no concurrent observers and does
no fallible work after the publication boundary; durable or concurrent backends
must supply their own atomic commit mechanism.
[`examples/replicate_once.zig`](examples/replicate_once.zig) is the
consumer template for the replication modules: live SQLite capture through a
checkpoint, tree listing, and a full restore, in one run of
`mise exec -- zig build example-replicate-once` (it links the host SQLite
for the executable only).
[`examples/sqlite_store_lifecycle.zig`](examples/sqlite_store_lifecycle.zig)
demonstrates store initialization and recovery, verified snapshot publication,
a held generation access and SQLite open specification, and the lock/lifecycle
boundary without linking SQLite. Run them with the three `example-*` commands
above. The project history is recorded in [`CHANGELOG.md`](CHANGELOG.md).

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
implementation and pinned Celld tree, plus Celld's immutable six-transition
replica captured by the real Litestream v0.5.11 binary. Every captured LTX
digest and reconstructed database digest is a known answer. Hermetic tests also
compact captured TX1 through TX4, stage that current flagged output, and apply
the legacy TX5/TX6 tail through the exact final database hash. The optional
`interop` step verifies a fresh Zig snapshot with the exact pinned Go decoder,
byte-matches synthetic compaction cases, and independently compacts the real
TX1–TX4 prefix with Go before decoding its database image. Its five-chain
matrix also proves that sequential Zig apply, a direct database model, and
apply of the compacted file produce the same pinned image for 512-, 1024-,
4096-, and 65,536-byte pages. Pinned Go first byte-matches all 12 source files,
then compacts those Zig bytes and byte-matches every final output. The separate
`litestream-interop` step requires a
binary reporting exactly v0.5.16. That reader restores the mixed Zig-L1 and
legacy-L0 capture plus the matrix's no-checksum maximum-page output to exact
image hashes. It also pins the checked-growth case's rejection: Litestream
forces no-checksum compaction during restore but retains the nonzero post-apply
checksum. This is a Litestream v0.5.16 limitation, not a Zig/Go byte mismatch.
The matrix images contain synthetic byte patterns and are not claimed to be
valid SQLite databases.

LTX v2 import and migration use `superfly/ltx` v0.4.0 at commit
`2af9b0cb7a6eebfb59c2ca76acc4ae3adf4b6a09` as their independent wire oracle.
The optional interoperability gate migrates v2-only, mixed v2/v3, and valid
SQLite-image inputs, then requires their complete canonical v3 bytes to equal
independently constructed current-Go `FileSpec` outputs. Celld is a secondary
v3 reader, writer, and deployment reference only; its crate contains no v2
implementation or v2 fixtures.

Release qualification and CI use the official archive, and CI extracts and
runs it only after checking its pinned SHA-256. Normal tests stay
network-free, replay the checked-in fuzz corpora, and run a deterministic
mutation suite; [docs/fuzzing.md](docs/fuzzing.md) documents the bounded native
fuzz run used in CI and longer local sessions.

## Resource budgets and benchmarks

The checked [resource-budget model](docs/resource-budgets.md) turns configured
limits into conservative decoder, encoder, staged-apply, compactor, and output
storage requirements. `resource-check` verifies those formulas and the
documented reference configurations without measuring wall-clock time.

`bench` runs the representative core suite: isolated zero, mixed, and
pseudorandom encode/decode cases at 4 KiB and 64 KiB; checked 1-, 4-, and
16-input compaction chains; and checked plus no-checksum staged apply. It
reports `ns/op`, median `ns/page`, logical and wire throughput, byte/page/event
counts, and apply callback counts. Arguments after `--` are forwarded to the
executable, which accepts `--filter all|encode|decode|compact|apply` and bounded
`--iterations 1..10000` options.
`bench-core` is an alias, while `bench-lz4` retains the focused raw-compressor
microbenchmark. Benchmark executables use `-Dbench-optimize`, independently of
the library/test `-Doptimize` setting, and default to `ReleaseFast`.
`benchmark-smoke` runs all 17 core cases and validates their bytes, digests,
semantics, and counters in a short mode. CI compiles both executables and runs
this smoke mode with `ReleaseSafe`, but never treats timing measurements as
pass/fail gates.

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
and all variable-size workspace during initialization. Pass `.v2` for a known
v2 object and `.v3` for a known v3 object; `LTX1` cannot distinguish them. Page
data is explicitly unverified and is overwritten by the next decoder
operation.

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
details, [docs/replication.md](docs/replication.md) for the replication
deployment contract, [docs/compaction.md](docs/compaction.md) for the bounded merge API,
[docs/apply.md](docs/apply.md) for the storage backend contract, and
[docs/resource-budgets.md](docs/resource-budgets.md) for workspace formulas.
The exact feature matrix is in
[docs/compatibility.md](docs/compatibility.md).

## Replication modules

Four additional modules extend the package toward a full SQLite-to-S3
replication library; see [docs/replication-roadmap.md](docs/replication-roadmap.md)
for the plan and current status. Import `ltx_wal` for bounded SQLite WAL
parsing with committed page maps and salt censes, `ltx_object` for the
storage-neutral object contract with its filesystem backend and conformance
suite, `ltx_s3` for S3-compatible stores (path-style SigV4, paginated
listings, object read/write/delete, and bucket creation over the
standard-library HTTP client), `ltx_replica` for the Litestream level ladder, restore planning, and
restore/compaction/retention executors over caller-owned workspaces, and
`ltx_capture` for the SQLite capture session that publishes no-checksum L0
transitions through an object client. The first three import only `std` and
`ltx`; `ltx_capture` declares its own minimal SQLite C surface and expects
the host build to link SQLite. Its live gate is
`mise exec -- zig build capture-integration -Doptimize=ReleaseSafe`, and the
S3 backend's gate is `mise run s3-integration`, which starts a pinned local
MinIO server and runs the backend-agnostic conformance suite against it.

## Quiescent SQLite store

Consumers that need durable filesystem publication can also import the optional
module as `ltx_sqlite`. Its `Store` borrows a `std.Io.Dir`, a non-empty
caller-owned copy/checksum workspace, and a `Lifecycle` callback pair. The
quiesce callback must stop new SQLite opens, checkpoint and close all owned
connections, and leave both generation names without `-wal`, `-shm`, or
`-journal` files. `store.acquire_generation()` resolves the manifest while
holding a shared advisory lock and returns a typed `GenerationAccess` containing
the exact encoded SQLite URI, the required `SQLITE_OPEN_READONLY |
SQLITE_OPEN_URI` flags, and the `PRAGMA query_only=ON` command. The host closes
all SQLite statements and connections before releasing that access.
The store's `std.Io` provider and backing context must outlive every access.
`store.backend()` plugs directly into `StagedApplier`.
`store.recover()` on a pristine directory durably creates the empty baseline;
the first snapshot also initializes it automatically before creating a database
slot. Interrupted first stages recover back to empty without guessing.

After a successful apply, `store.current()` returns the manifest-bound position,
page size, exact length, generation, and database filename for diagnostics; it
is not permission to open that filename. If apply returns
`error.ApplyPublishIndeterminate`, the store deliberately keeps both the
lifecycle gate and exclusive store lock held; call `store.recover()` until it
succeeds before opening SQLite or starting another apply. Full deployment
constraints and crash outcomes are in [the SQLite store guide](docs/sqlite-store.md).
`store.current_state()` reports whether the store is idle, acquiring, staging,
or recovery-required, while `store.last_failure()` exposes the adapter-specific
cause hidden behind a generic staged-apply backend error.

Store changes are qualified with real child-process termination at every
baseline and publication sync/rename boundary. `zig build sqlite-integration`
additionally builds a real WAL-mode SQLite A -> B -> C chain, crash-replays its
first publication, growth, shrink, and slot reuse through those boundaries, and
checks retained leases, stale access epochs, checksum-scanning recovery, exact
bytes, read-only queries, retained prior-generation bytes, and
`PRAGMA integrity_check`. It also publishes the complete captured
Litestream chain and verifies the final key/value state through a leased,
immutable read-only SQLite handle. SQLite remains linked only into the
integration test executable, not either library module.
