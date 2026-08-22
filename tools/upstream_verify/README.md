# Pinned Go verifier

This optional tool verifies `ltx-zig` encoder output with the Go compatibility
oracle pinned in `go.mod` to upstream commit
`8cb8f8ebaf8f57c9b0e1041a27d5444032ea0643`.

Run it through the repository build so the input is freshly generated:

```sh
mise exec -- zig build interop
```

The generated one-page file is required to equal the pinned current-Go
snapshot fixture byte for byte: 168 physical bytes, file checksum
`eb5121d56d33a656`, and Go logical byte count 648. This exercises the Zig fast
match compressor rather than only format-compatible literal output.

The same command generates three Zig compaction outputs. The verifier
independently reconstructs their input files, runs the pinned Go
`ltx.NewCompactor`, requires complete byte equality, and then decodes and checks
the Zig outputs with Go. The three-input `merge` case covers newest-page
precedence, final-commit shrinkage, current flagged blocks, and zeroed WAL/salt/
node metadata. The `deletion` case covers a checksummed snapshot followed by an
exactly contiguous incremental deletion to commit zero. The `no-checksum` case
covers the mode emitted by Celld's storage-level compactor and explicitly sets
the pinned Go compactor's output flags to match.

It also generates and verifies a five-chain differential matrix:

- three checksummed 512-byte-page transitions that grow to five pages;
- three checksummed 4096-byte-page transitions with sparse updates and a final
  shrink to three pages;
- two no-checksum transitions at the 65,536-byte maximum page size that shrink
  to one page;
- a checksummed three-page 1024-byte snapshot followed by deletion to empty;
- the committed legacy unflagged 512-byte zero-page snapshot followed by a
  current incremental.

For each matrix case, the verifier reconstructs the current inputs
independently, requires byte equality for all 12 Zig source files, runs
`ltx.NewCompactor` over those Zig bytes, requires complete output byte equality,
decodes the compacted database with Go, and checks a pinned SHA-256. It
also verifies the final header, pages, checksum mode, current page flags, and
zeroed WAL offset, WAL size, salts, and node ID. The legacy/current case proves
that historical unflagged input is rewritten into the current flagged page
profile.

The five decoded database hashes, in the order above, are:

```text
c89c89ca0c8c8a5ad990add46f40c64237cc847535b7c46a1338671f24727203
748180e5b2dcef3c390c2b9b26700b20df220c43455bc52f75d41e769b6f7adc
1f2d41b212c74e121e69ba1f71cdf254ce7b478dfb675bca590a1bb9c952354f
e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
a84f98fa7bc9cfbb6ee11fc4eb67c730d9648d3a32a4933b289d5cc28fc72865
```

The interoperability gate also checks three explicit migration outputs. The
historical v0.4.0 module first reproduces the committed v2 sources. Zig then
compacts the v2-only chain, an equivalent mixed v2/v3 chain, and the valid v2
SQLite snapshot into canonical v3. The current pinned Go module independently
constructs the expected canonical outputs for all three routes, requires
complete byte equality, decodes each output, and checks the final database
SHA-256.

This proves interoperability with the exact pinned Go library, not integration
with a running Litestream deployment. The step may download Go modules. The
normal Zig test suite is hermetic and does not invoke it.

The committed current-Go snapshot-zero, empty, incremental, no-checksum, and
near-lock-page vectors can be regenerated individually on standard output
through the root build:

```sh
mise exec -- zig build upstream-fixture -Dfixture=incremental > /tmp/go-incremental.ltx
```

`mise exec -- zig build check-fixtures` regenerates and byte-compares all five
current fixtures as well as the v2 fixtures before checking every binary/hex
pair.

The separate historical module pins the last canonical unflagged-frame writer.
It regenerates the compressed one-page and mixed compressed/stored fixtures:

```sh
mise exec -- zig build upstream-legacy-fixture -Dlegacy-fixture=snapshot-zero > /tmp/go-legacy-zero.ltx
mise exec -- zig build upstream-legacy-fixture -Dlegacy-fixture=mixed > /tmp/go-legacy-mixed.ltx
```

Check both committed historical vectors against that pinned writer with
`mise exec -- zig build check-legacy-fixtures`.

After reviewing changes to the hex mirrors, regenerate all directly consumable
binary fixtures with `mise exec -- zig build materialize-fixtures`. Confirm the
committed pairs without modifying them with `mise exec -- zig build
check-fixtures`.

The materializer also covers the nested
`tests/fixtures/celld_litestream_v0511/replica/ltx/0` corpus. Those six files
were captured by the real Litestream v0.5.11 binary and copied from the pinned
Celld golden tree; no local generator is an authority for their contents.
Their provenance and hashes are documented in that fixture directory.
