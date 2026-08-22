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
The Zig encoder is separately required to reproduce the complete
`go_v3_snapshot_zero_page.ltx` bytes, not merely its decoded semantics.

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

## Malformed corpus

`tests/malformed.zig` derives malformed checksum, truncated-header,
truncated-compressed-payload, legacy descriptor/footer, invalid-index,
unsupported-flag, page-order, and trailing-byte cases deterministically from
the current and historical one-page fixtures. Every strict byte prefix of both
is exercised, so separate redundant truncated payload files are unnecessary.
The tests assert controlled errors and failed-state poisoning.
