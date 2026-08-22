# Fixture manifest

The `.ltx` files are the canonical, directly consumable fixture artifacts used
by the Zig tests. Each has a lowercase hexadecimal `.hex` review mirror;
whitespace in those mirrors is ignored by the materializer. Every SHA-256 below
is for the binary artifact. All headers have zero WAL metadata and node ID
unless stated otherwise, and canonical encoders zero the 20 reserved header
bytes.

## Current Go oracle fixtures

These files come from `github.com/superfly/ltx` commit
`8cb8f8ebaf8f57c9b0e1041a27d5444032ea0643`, use explicit format `.v3`, and
use current flagged raw LZ4 blocks. Regenerate their binary payloads with:

```sh
mise exec -- zig build upstream-fixture -Dfixture=<name>
```

| File / selector | Semantic pages | Header: flags, page size, commit, TXIDs, timestamp, pre-checksum | Trailer: post-checksum, file checksum | Binary SHA-256 |
| --- | --- | --- | --- | --- |
| `go_v3_snapshot_zero_page.ltx` / `snapshot-zero` | Snapshot page 1 = 512 zero bytes | `0`, `512`, `1`, `1..1`, `0`, `0000000000000000` | `efb1f44fecd99000`, `eb5121d56d33a656` | `7ab2cbb91c15c977abcb7256ac471ee1f4f78343d16b1bacd55edd3d2d930e4a` |
| `go_v3_empty_snapshot.ltx` / `empty` | Empty snapshot | `0`, `512`, `0`, `1..1`, `0`, `0000000000000000` | `8000000000000000`, `ef752d544ac8c48f` | `b270619913b21cecb628827c679749ae6277159391ac0223762f408f57ff7287` |
| `go_v3_incremental.ltx` / `incremental` | Pages 1 and 3 = 512 bytes of `31` and `33` | `0`, `512`, `3`, `2..4`, `-1000`, `8000000000001234` | `8000000000005678`, `d1f8ea546c262bd3` | `3a5f87b53d70343c7e19d760b7ff2536b61b229673ae832af15bcf8d18966956` |
| `go_v3_no_checksum.ltx` / `no-checksum` | Page 2 = 4096 bytes of `a5` | `2`, `4096`, `2`, `5..5`, `2000`, `0000000000000000` | `0000000000000000`, `c231c44dd37c4fc6` | `3c27d6dbb89142fd4054f80d3c4a84027346e71b6dd2d7a87e096359aade7f89` |
| `go_v3_near_lock_page.ltx` / `near-lock` | 65536-byte pages 16384/16386 = `84`/`86`; lock page 16385 omitted | `0`, `65536`, `16386`, `7..8`, `3000`, `8000000000000111` | `8000000000000222`, `e2f9b76966a755f5` | `e72968228256e29ecb024f0e29a056fbf0ee2c872f7c2589f8bb96901c3f246e` |

The generator lives in `tools/upstream_verify/fixturegen`; its `go.mod` pins
the exact oracle pseudo-version and `go.sum` pins transitive content hashes.
The aggregate `mise exec -- zig build check-fixtures` gate regenerates and
byte-compares all five files with that pinned writer.
The Zig encoder is separately required to reproduce the complete
`go_v3_snapshot_zero_page.ltx` bytes, not merely its decoded semantics.

## Historical Go v2 oracle fixtures

These files come from `github.com/superfly/ltx` v0.4.0, commit
`2af9b0cb7a6eebfb59c2ca76acc4ae3adf4b6a09`. The separate
`tools/v2_fixturegen` module pins that release and its LZ4 dependency by Go
module checksum. They require explicit format `.v2`: v2 and v3 both use
`LTX1`, while v2 has a four-byte page header and no on-disk version field.

Regenerate both the binary artifacts and reviewed hex mirrors, then verify
them against the pinned writer with:

```sh
(cd tools/v2_fixturegen && GOWORK=off go run . --write ../../tests/fixtures)
mise exec -- zig build check-v2-fixtures
```

| File / selector | Semantic pages | Header: flags, page size, commit, TXIDs, timestamp, pre-checksum | Trailer: post-checksum, file checksum | Bytes | Binary SHA-256 |
| --- | --- | --- | --- | ---: | --- |
| `go_v2_mixed_snapshot.ltx` / `mixed` | Snapshot page 1 = 512 zero bytes; page 2 = fixed-seed xorshift bytes; the pinned LZ4 writer emits compressed and stored frames respectively | `0`, `512`, `2`, `1..1`, `0`, `0000000000000000` | `ff273ef830778b70`, `b5434126ea96be07` | 719 | `e07e756bf683ef73eb0628177baa8f3a64f59bfbd162957189b626f1331e2eae` |
| `go_v2_empty_snapshot.ltx` / `empty` | Empty snapshot; exercises the four-byte page terminator directly followed by the page index | `0`, `512`, `0`, `1..1`, `0`, `0000000000000000` | `8000000000000000`, `bc114ac8c457e208` | 129 | `1f518147c9c690b0494d6a9c9eb6884f6131bd6e27c739bb4fcc2f9db4971088` |
| `go_v2_sqlite_empty.ltx` / `sqlite-empty` | Snapshot page 1 is a valid empty 512-byte SQLite 3 database with an empty table-leaf page | `0`, `512`, `1`, `1..1`, `0`, `0000000000000000` | `8c322d76563177ee`, `da434cd81503cce8` | 244 | `263808f41dda5869000e8b722efd1e8d866c6a5dbde594b4b8efbd226f35e09a` |
| `go_v2_incremental.ltx` / `incremental` | Contiguous successor to `mixed`: pages 1 and 3 become 512 bytes of `31` and `33`; unchanged page 2 retains the xorshift bytes | `0`, `512`, `3`, `2..4`, `-1000`, `ff273ef830778b70` | `b6a0600a0173c6ad`, `9617bdbd486343c2` | 230 | `f960103ca1bf1df2475d4f9a229c7863949f9c4394b35096ae90a257f15e5224` |
| `go_v2_no_checksum.ltx` / `no-checksum` | Page 2 = 4096 bytes of `a5` | `2`, `4096`, `2`, `5..5`, `2000`, `0000000000000000` | `0000000000000000`, `ae9072bfa9004879` | 193 | `76b3dfdaa958ad939f9adf4a2e22563452eb8480a006883a995c9cfce775d966` |
| `go_v2_near_lock_page.ltx` / `near-lock` | 65,536-byte pages 16,384 and 16,386 = `84` and `86`; lock page 16,385 is omitted | `0`, `65536`, `16386`, `7..8`, `3000`, `8000000000000111` | `8000000000000222`, `bf1922ef87e1dd8f` | 746 | `35a89b6af9e8f5b29377ad5e904444eb62cef5cf87ae8a512aa400b5a3058e30` |

The mixed snapshot and incremental form a genuine checksummed chain. Applying
the second file over the first yields three pages and the incremental trailer's
post-apply checksum; the 1,536-byte final image has SHA-256
`d83e04db4d5ed75b3d5cd7d5b910690162c26cfbd24584f8f8e3bbec607aa475`.
The SQLite fixture duplicates the byte layout constructed by
`tests/sqlite_store.zig` for an empty database. Its decoded 512-byte database
has SHA-256
`2d3f4873f9cbd65802382dc11067c1e52d72cdaa464bda1f5072faac002e95f5`,
passes `PRAGMA integrity_check`, and has an empty `sqlite_schema`.

## Secondary and historical fixtures

| File | Origin and reproduction | Semantic contents and expected header | Expected trailer | Binary SHA-256 |
| --- | --- | --- | --- | --- |
| `celld_v052_two_page_snapshot.ltx` | `denoland/celld` tree `89e4ffc53a14ecb496d2ca5014ff9d19b0061ad9`, test `encoder_matches_superfly_ltx_v0_5_2_bytes`; run that Rust test to reproduce/verify the vector | `.v3` flagged blocks; pages 1/2 are 1024 bytes of `81` / repeated `abcd`; flags `0`, commit `2`, TXIDs `1..1`, timestamp `1000`, pre `0` | post `a09639bc718d9c58`; file `dc2f8726a386540e` | `b7c4c3d21a1c009c297934723f737199cbe392164a95f05a2a3763dda059eecb` |
| `go_v3_legacy_unflagged.ltx` | Historical Go `FileSpec.WriteTo` at `133c1b1dba55dfb8033affedb3d400aaa3d8b807`; `mise exec -- zig build upstream-legacy-fixture -Dlegacy-fixture=snapshot-zero` | `.v3` unflagged compressed LZ4 frame; page 1 = 512 zero bytes; flags `0`, commit `1`, TXIDs `1..1`, timestamp `0`, pre `0` | post `efb1f44fecd99000`; file `ae80e1069c9bc795` | `cebdc979fea5b00f51eacdcdeef579f6b87a5b5fb901f4fb952d857eef19da1f` |
| `go_v3_legacy_mixed.ltx` | Historical Go `FileSpec.WriteTo` at `133c1b1dba55dfb8033affedb3d400aaa3d8b807`; `mise exec -- zig build upstream-legacy-fixture -Dlegacy-fixture=mixed` | `.v3` unflagged frames; page 1 = 512 zero bytes (compressed), page 2 = fixed-seed xorshift bytes (stored); flags `0`, commit `2`, TXIDs `1..1`, timestamp `0`, pre `0` | post `ff273ef830778b70`; file `c33c5c9b2434d957` | `42c81f74ae54b11cf22768223b99a6c2f271e06559ccb619bc8b553533fcb2c5` |

The historical generator is separately pinned because current Go only emits
flagged blocks. Both legacy files use the exact upstream profile: one
independent 64 KiB block, a content checksum, and no optional descriptor
fields. The mixed fixture proves both compressed and high-bit stored blocks.

The Zig encoder also reproduces the complete
`celld_v052_two_page_snapshot.ltx` bytes. Together with the current-Go
snapshot equality test, this pins match selection and compressor state reset
independently of Zig's decoder.

## Real Litestream capture chain

`celld_litestream_v0511/` contains the six-file L0 replica chain captured by
the pinned Celld tree using the real Litestream v0.5.11 binary and SQLite
3.51.0. The snapshot and five contiguous incrementals are immutable upstream
reader fixtures, not output synthesized by this project. Their complete
provenance, artifact and database-image hashes, semantic final state, scope,
and Apache-2.0 attribution are in the
[capture manifest](celld_litestream_v0511/README.md).

## Malformed corpus

`tests/malformed.zig` derives malformed checksum, truncated-header,
truncated-compressed-payload, legacy descriptor/footer, invalid-index,
unsupported-flag, page-order, and trailing-byte cases deterministically from
the current and historical one-page fixtures. Every strict byte prefix of both
is exercised, so separate redundant truncated payload files are unnecessary.
The tests assert controlled errors and failed-state poisoning.
