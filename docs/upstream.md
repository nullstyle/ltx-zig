# Upstream audit

## Pinned revisions

The implementation and compatibility fixtures were developed against these
exact revisions:

- [`superfly/ltx`](https://github.com/superfly/ltx/tree/8cb8f8ebaf8f57c9b0e1041a27d5444032ea0643):
  `8cb8f8ebaf8f57c9b0e1041a27d5444032ea0643`
- [TigerBeetle repository containing `docs/TIGER_STYLE.md`](https://github.com/tigerbeetle/tigerbeetle/blob/97c7a8ef385270ebe0e1b75959d3d21d134629df/docs/TIGER_STYLE.md):
  `97c7a8ef385270ebe0e1b75959d3d21d134629df`
- [`superfly/ltx-rs`](https://github.com/superfly/ltx-rs/tree/ceabe1fe1b3076094805244ee6a3acff4d43d1e8):
  `ceabe1fe1b3076094805244ee6a3acff4d43d1e8`
- [`denoland/celld` LTX crate](https://github.com/denoland/celld/tree/89e4ffc53a14ecb496d2ca5014ff9d19b0061ad9/crates/ltx):
  `89e4ffc53a14ecb496d2ca5014ff9d19b0061ad9`
- [`pierrec/lz4` v4.1.23](https://github.com/pierrec/lz4/tree/cd9d7a4f66405a92f4881933816b828b0f7d5fe2):
  `cd9d7a4f66405a92f4881933816b828b0f7d5fe2`
- [SQLite 3.53.4 source mirror](https://github.com/sqlite/sqlite/tree/b09c88c14082339b66c7b7158d609a771e64ca69):
  `b09c88c14082339b66c7b7158d609a771e64ca69`

At the pinned TigerBeetle tree, `docs/TIGER_STYLE.md` has blob
`d4cefaa6249483357a41b786d7e042f1d94a3ea5`; its last modifying commit is
`1e40c4c876216b4e27d70fa2c45adb47124e2a7b`.

The legacy-v3 audit additionally traced Go history. Unflagged LZ4 frames were
emitted from v3 introduction commit
`2e6df57fc041819c837bba4f94438fec5868b85e` through
`133c1b1dba55dfb8033affedb3d400aaa3d8b807`; those revisions share encoder
blob `fde8297bdd4a2ee003dacddafb430630d5c0f44e`. The current flagged raw-block
encoding entered main at `d017048fab4a3e0850cd1e270870a311bcc16009`.
A size-prefixed complete-frame experiment at
`fdbcb22c829f6fab749b76554bf53d5223a98160` was never merged and is not part of
the compatibility target.

## Files inspected

For Go: `README.md`, `CLAUDE.md`, `ltx.go`, `checksum.go`, `encoder.go`,
`decoder.go`, `file_spec.go`, all core tests, and relevant `cmd/ltx` apply,
encode, dump, and verify code. The pinned repository passed `go test ./...`.
The apply audit also traced page writes, decoder finalization, truncation, and
post-apply checksum verification.

For TigerStyle: `docs/TIGER_STYLE.md` at the pinned tree.

For Rust: `README.md`, `Cargo.toml`, every file under `src/`, and
`tests/compat.rs` plus its test support. Rust is a secondary design reference
only: it implements an obsolete pre-v3 layout with four-byte page headers,
whole-block LZ4 framing, and no page index.

For `denoland/celld`: `crates/ltx/README.md`, `Cargo.toml`,
`reference/ltx-format.md`, `src/codec.rs`, `src/ltx.rs`, `src/lz4_block.rs`,
`src/replica.rs`, `src/faults_inject.rs`, and `tests/differential_xtool.rs`.
Celld is a secondary interoperability and deployment reference, not the
valid-output oracle. Its crate pins Go LTX v0.5.2 and provides a byte-exact port
of Go's block compressor plus a dual reader for current flagged raw blocks and
legacy unflagged LZ4 frames. It also validates exact decompressed length, the
declared index size, and the trailer. Its `Vec`, `BTreeMap`, `HashMap`, and
read-to-end design is intentionally not a memory model for this allocation-free
Zig core, and it does not perform Zig's exact one-to-one index/frame
cross-check.

For raw-block compression: the current Go oracle pins
`github.com/pierrec/lz4/v4 v4.1.23` with module content hash
`h1:oJE7T90aYBGtFNrI8+KbETnPymobAhzRrR8Mu8n1yfU=`. The files inspected were
`internal/lz4block/block.go`, its tests, and `LICENSE`. Zig ports the fast
compressor's search, table-update, match-extension, and output order exactly;
the independently written Celld port is a second byte-exact reference. The
algorithm is Copyright (c) 2015 Pierre Curto under BSD-3-Clause, retained in
[`LICENSE.pierrec-lz4`](../LICENSE.pierrec-lz4). It remains separate from and
must accompany the project's [MIT License](../LICENSE) where applicable.

## Apply-model evidence

The pinned Go command's
[`applyLTXFile`](https://github.com/superfly/ltx/blob/8cb8f8ebaf8f57c9b0e1041a27d5444032ea0643/cmd/ltx/apply.go#L69-L133)
writes decoded pages directly into the destination before
[`Decoder.Close()`](https://github.com/superfly/ltx/blob/8cb8f8ebaf8f57c9b0e1041a27d5444032ea0643/decoder.go#L74-L123)
performs terminal verification. It truncates and recomputes the database
checksum afterward. A late structural or checksum failure can therefore leave
partial destination mutations. Its
[`TestApplyLTXFileToExistingDB`](https://github.com/superfly/ltx/blob/8cb8f8ebaf8f57c9b0e1041a27d5444032ea0643/cmd/ltx/apply_test.go#L79-L112)
also establishes snapshot replacement over an existing database as intended
behavior. Zig uses Go's page placement and final-size semantics, but not this
mutation ordering.

Celld keeps decoded pages private until its
[`decode_file_inner`](https://github.com/denoland/celld/blob/89e4ffc53a14ecb496d2ca5014ff9d19b0061ad9/crates/ltx/src/ltx.rs#L429-L452)
has completed decoder verification. Its database-image path
[`build_database_image`](https://github.com/denoland/celld/blob/89e4ffc53a14ecb496d2ca5014ff9d19b0061ad9/crates/ltx/src/replica.rs#L768-L842)
rejects page-size mismatches, constructs private state, gives later transitions
precedence, and applies the final commit size. Restore then writes a temporary
file, syncs it, and renames it through
[`write_file_atomic`](https://github.com/denoland/celld/blob/89e4ffc53a14ecb496d2ca5014ff9d19b0061ad9/crates/ltx/src/replica.rs#L855-L875).
Celld's snapshot image also zero-fills the omitted SQLite lock page in
[`decode_database_image`](https://github.com/denoland/celld/blob/89e4ffc53a14ecb496d2ca5014ff9d19b0061ad9/crates/ltx/src/ltx.rs#L470-L500).
This private-stage, verify, construct, and single-publication ordering is the
deployment model adopted by `StagedApplier`; Celld's allocation-heavy full
image is not.

Neither upstream is a complete live SQLite adapter model. Celld explicitly
leaves follow-mode application
[`unimplemented`](https://github.com/denoland/celld/blob/89e4ffc53a14ecb496d2ca5014ff9d19b0061ad9/crates/ltx/src/replica.rs#L28-L35),
and its restore path does not define coordination with open SQLite connections,
WAL files, or SHM files. The Zig backend contract additionally requires the
authoritative position check, complete image publication, and position advance
to be atomic.

## SQLite publication evidence

The filesystem adapter design was checked against SQLite's published locking,
journaling, backup, and corruption guidance. SQLite explicitly classifies
[renaming or unlinking an open database](https://www.sqlite.org/howtocorrupt.html#_unlinking_or_renaming_a_database_file_while_in_use)
as undefined and corruption-prone. A WAL file can contain committed state that
is absent from the main database, so it must remain paired with that database
until SQLite has checkpointed and closed it through the same VFS
([WAL persistence](https://www.sqlite.org/wal.html#the_wal_file)). A hot rollback
journal has the same recovery significance. Consequently, raw LTX page writes
are permitted only in a private generation after an application-owned gate has
drained and closed every SQLite connection. A filesystem advisory lock
coordinates participating processes but cannot make an arbitrary SQLite client
cooperate.

SQLite's Online Backup API is not a byte-exact publication substitute. At
backup completion SQLite intentionally increments the destination schema cookie
in [`backup.c`](https://github.com/sqlite/sqlite/blob/b09c88c14082339b66c7b7158d609a771e64ca69/src/backup.c#L437-L449),
and committing the destination also changes page-one transaction metadata. The
[database-header layout](https://www.sqlite.org/fileformat2.html#the_database_header)
places those fields inside the bytes covered by LTX's page-one checksum. A
SQLite 3.51.0 experiment copying the same 2048-byte source into fresh and
existing destinations confirmed differences at the change-counter,
schema-cookie, and version-valid-for fields. The backup images were valid
SQLite databases, but neither was the exact verified LTX image.

The adapter therefore uses two closed database generations and one checksummed
manifest as the sole authority. Publication prepares and syncs the inactive
generation, syncs a temporary manifest containing both the image selection and
LTX position, then atomically renames that manifest. This also exposes a
general storage fact that the earlier abstract backend contract omitted: if
the rename succeeds and the following directory sync fails, the visible commit
may have changed while crash durability is unknown. That outcome is reported
separately as `ApplyPublishIndeterminate` and requires manifest recovery; it is
never treated as an ordinary failure followed by stage deletion.

## Compatibility decisions and disagreements

The current Go encoder and its tests are the valid-output oracle. The Zig
decoder deliberately rejects malformed files that the Go decoder happens to
accept. These are hardening differences, not silent reinterpretations.

1. **Version selection.** The Go README correctly says v2 and v3 both use
   `LTX1` and need out-of-band version selection. `NewDecoder`, however, takes
   no version and `Header.UnmarshalBinary()` assigns v3 from magic alone. Every
   Zig entry point requires `FormatVersion`; only `.v3` is supported.

2. **Section count.** Current Go README and code have header, page block, page
   index, and trailer. `CLAUDE.md` still describes three sections and omits the
   index. Zig implements the four-section format.

3. **Decompressed length.** README requires exactly `Header.PageSize`. Go calls
   `UncompressBlock` but ignores its returned length. Zig rejects short or long
   output.

4. **Index validation.** README describes sorted, one-to-one entries with exact
   offsets, frame sizes, and an index byte-size field. Go's decoder stores
   entries in a map, accepts duplicates/order problems and integer truncation,
   ignores the declared byte size, and never compares entries with frames. Zig
   requires canonical varints and exact correspondence with observed frames.

5. **Snapshot completeness.** Documentation says snapshots contain every page
   through `Commit`, excluding SQLite's lock page. The Go encoder checks start
   and adjacency but not the final page; the decoder has an explicit TODO. Zig
   verifies the complete range before accepting the page sentinel.

6. **Trailer validation.** Go has `Trailer.Validate()` and unit tests for
   checksum formatting, but normal decoder close does not call it. Zig always
   validates it before producing `VerifiedLTX`.

7. **Reserved header bytes.** The Go decoder ignores bytes 80 through 99 and
   the canonical encoder zeros them. Zig follows that compatibility behavior:
   accept and hash any values, expose no semantics, and always emit zero.

8. **Timestamp signedness.** README does not specify signedness. Go uses `int64`
   and accepts negative timestamps; Rust rejects pre-epoch values. Zig uses
   `i64`, matching Go.

9. **Empty database checksum.** `ChecksumReader` returns zero for empty input,
   but current encoder behavior and decoder tests use `ChecksumFlag` alone.
   Zig selects the wire-tested value `0x8000000000000000` and has a pinned Go
   fixture for it.

10. **Truncation and trailing bytes.** Go's decoder reads the remainder without
    a bound, can panic when fewer than eight bytes remain after the page block,
    and does not require exact physical EOF. Zig bounds every read, reports
    truncation, and rejects trailing bytes.

11. **Page validation.** The Go encoder rejects pages above `Commit`, lock-page
    frames, duplicates, and out-of-order pages. The decoder does not. Zig uses
    the canonical encoder behavior in both directions.

12. **Contiguity.** Go's range-oriented `IsContiguous()` permits overlaps and
    does not compare checksums. Zig's transition check requires the exact
    pre-apply TXID and, when enabled, the exact pre-apply checksum.

13. **No-checksum empty files.** The current Go encoder's validations make this
    combination impossible to emit: post zero passes no-checksum validation but
    fails its later deletion check, while the checksum flag fails no-checksum
    validation. Zig permits the internally consistent representation with both
    database checksums zero. This is an intentional, documented divergence.

14. **Legacy rollout evidence.** Celld retains both flagged raw-block and
    unflagged frame decoders under v3 and documents reader-first deployment.
    This independently confirms that the unchanged version marker created a
    real rollout constraint. Zig decodes the canonical historical profile:
    one independent 64 KiB block, a content checksum, and no optional frame
    fields. Standard LZ4 frame profiles that upstream never emitted remain an
    explicit `UnsupportedPageEncoding` boundary.

The unflagged v3 LZ4-frame encoding was introduced with v3 and later replaced
without a version bump. Two fixtures from the last historical writer commit
`133c1b1dba55dfb8033affedb3d400aaa3d8b807` exercise compressed and stored
blocks. Frame descriptor and physical payload bytes are excluded from LTX's
logical file checksum, while the decompressed page and LZ4 XXH32 content
checksum are verified.

## Fixture provenance

The per-fixture generation command, semantic header/trailer values, and hashes
are catalogued in [`tests/fixtures/README.md`](../tests/fixtures/README.md).

The current Go fixtures in `tests/fixtures/` were generated with the pinned Go
`NewEncoder`, directly or through `FileSpec.WriteTo`. The SHA-256 values of the
binary artifacts are:

- `go_v3_snapshot_zero_page`: `7ab2cbb91c15c977abcb7256ac471ee1f4f78343d16b1bacd55edd3d2d930e4a`
- `go_v3_empty_snapshot`: `b270619913b21cecb628827c679749ae6277159391ac0223762f408f57ff7287`
- `go_v3_incremental`: `3a5f87b53d70343c7e19d760b7ff2536b61b229673ae832af15bcf8d18966956`
- `go_v3_no_checksum`: `3c27d6dbb89142fd4054f80d3c4a84027346e71b6dd2d7a87e096359aade7f89`
- `go_v3_near_lock_page`: `e72968228256e29ecb024f0e29a056fbf0ee2c872f7c2589f8bb96901c3f246e`
- legacy unflagged fixture: `cebdc979fea5b00f51eacdcdeef579f6b87a5b5fb901f4fb952d857eef19da1f`
- legacy mixed fixture: `42c81f74ae54b11cf22768223b99a6c2f271e06559ccb619bc8b553533fcb2c5`
- `celld_v052_two_page_snapshot`: `b7c4c3d21a1c009c297934723f737199cbe392164a95f05a2a3763dda059eecb`

The 211-byte Celld vector is copied from the pinned crate's byte-exact
compressor test, where it is asserted equal to Go LTX v0.5.2
`FileSpec.WriteTo` output. The test originated in Celld commit
`ae8fac053d79f971bfcb996054bb43eb2f9b05da` and remains present at the pinned
tree. It covers two distinct normal match-compressed 1024-byte pages, a
multi-entry page index, post-apply checksum `a09639bc718d9c58`, and file
checksum `dc2f8726a386540e`.

The separately pinned historical generator reproduces both legacy fixtures.
The 725-byte mixed vector contains a compressed zero page followed by a stored
512-byte fixed-seed xorshift page. Its post-apply checksum is
`ff273ef830778b70`, its file checksum is `c33c5c9b2434d957`, and the current Go
oracle verifies it. Regenerate it with `mise exec -- zig build
upstream-legacy-fixture -Dlegacy-fixture=mixed`.

The pinned Go generator in `tools/upstream_verify/fixturegen` reproduces three
additional vectors: a two-page incremental with a negative timestamp, a
4096-byte-page no-checksum incremental, and a maximum-65536-byte-page
incremental whose page numbers straddle the SQLite lock page. Their file
checksums are respectively `d1f8ea546c262bd3`, `c231c44dd37c4fc6`, and
`e2f9b76966a755f5`. The generated base fixtures are mutated hermetically in Zig
tests to cover bad checksums, structural truncation, and invalid indexes.

Known answers include:

- `CRC64-ISO("123456789") = b90956c775a41001`
- `ChecksumPage(1, 512 zero bytes) = efb1f44fecd99000`
- flagged fixture file checksum `eb5121d56d33a656`
- empty snapshot file checksum `ef752d544ac8c48f`

`mise exec -- zig build fixturegen` emits the exact 168-byte current-Go
snapshot-zero fixture with match-compressed LZ4, file checksum
`eb5121d56d33a656`, and Go logical byte count 648. The Zig encoder also
reproduces the complete 211-byte Celld/Go v0.5.2 two-page vector. These
full-file comparisons supplement the raw-block known answers and round trips.
With an intentionally smaller 515-byte compressed-page cap, the same input
exercises the literal fallback and retains its prior 660-byte known answer with
file checksum `f9b895f23744f218`.

`mise exec -- zig build interop` performs that Go verification from the build
graph. Its Go module pins the pseudo-version resolving exactly to the recorded
Go commit; unlike the normal test suite, it may download modules.
