# Pinned Go verifier

This optional tool verifies `ltx-zig` encoder output with the Go compatibility
oracle pinned in `go.mod` to upstream commit
`8cb8f8ebaf8f57c9b0e1041a27d5444032ea0643`.

Run it through the repository build so the input is freshly generated:

```sh
mise exec -- zig build interop
```

This step may download Go modules. The normal Zig test suite is hermetic and
does not invoke it.

The committed current-Go snapshot-zero, empty, incremental, no-checksum, and
near-lock-page vectors can be regenerated individually on standard output
through the root build:

```sh
mise exec -- zig build upstream-fixture -Dfixture=incremental > /tmp/go-incremental.ltx
```

After reviewing changes to the hex mirrors, regenerate all directly consumable
binary fixtures with `mise exec -- zig build materialize-fixtures`. Confirm the
committed pairs without modifying them with `mise exec -- zig build
check-fixtures`.
