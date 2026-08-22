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

This proves interoperability with the exact pinned Go library, not integration
with a running Litestream deployment. The step may download Go modules. The
normal Zig test suite is hermetic and does not invoke it.

The committed current-Go snapshot-zero, empty, incremental, no-checksum, and
near-lock-page vectors can be regenerated individually on standard output
through the root build:

```sh
mise exec -- zig build upstream-fixture -Dfixture=incremental > /tmp/go-incremental.ltx
```

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
