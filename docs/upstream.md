# Upstream audit

## Pinned revisions

The implementation and compatibility fixtures were developed against these
exact revisions:

- [`superfly/ltx` v0.4.0 (LTX v2 import oracle)](https://github.com/superfly/ltx/tree/2af9b0cb7a6eebfb59c2ca76acc4ae3adf4b6a09):
  `2af9b0cb7a6eebfb59c2ca76acc4ae3adf4b6a09`
- [`superfly/ltx`](https://github.com/superfly/ltx/tree/8cb8f8ebaf8f57c9b0e1041a27d5444032ea0643):
  `8cb8f8ebaf8f57c9b0e1041a27d5444032ea0643`
- [TigerBeetle repository containing `docs/TIGER_STYLE.md`](https://github.com/tigerbeetle/tigerbeetle/blob/97c7a8ef385270ebe0e1b75959d3d21d134629df/docs/TIGER_STYLE.md):
  `97c7a8ef385270ebe0e1b75959d3d21d134629df`
- [`superfly/ltx-rs`](https://github.com/superfly/ltx-rs/tree/ceabe1fe1b3076094805244ee6a3acff4d43d1e8):
  `ceabe1fe1b3076094805244ee6a3acff4d43d1e8`
- [`denoland/celld` LTX crate](https://github.com/denoland/celld/tree/89e4ffc53a14ecb496d2ca5014ff9d19b0061ad9/crates/ltx):
  `89e4ffc53a14ecb496d2ca5014ff9d19b0061ad9`
- [`denoland/celld` v0.4.0 LTX crate (architecture re-audit)](https://github.com/denoland/celld/tree/a52f9905425bc41134d817694bdc2c50bcc5e856/crates/ltx):
  `a52f9905425bc41134d817694bdc2c50bcc5e856`
- [`benbjohnson/litestream` v0.5.11](https://github.com/benbjohnson/litestream/tree/016c368704e63db0088b9b61e2e96c0019f11832):
  `016c368704e63db0088b9b61e2e96c0019f11832`
- [`benbjohnson/litestream` v0.5.16](https://github.com/benbjohnson/litestream/tree/6d61ef5d007756d62e473daee4c760ac395a55c6):
  `6d61ef5d007756d62e473daee4c760ac395a55c6`
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

The separate v0.4.0 pin is the historical LTX v2 wire oracle. V2 and v3 both
start with `LTX1` and contain no on-disk version discriminator, so the pin does
not establish a detection heuristic. Callers must carry trusted version
metadata into every decode, apply, or compaction input.

## Files inspected

For current Go v3: `README.md`, `CLAUDE.md`, `ltx.go`, `checksum.go`,
`encoder.go`, `decoder.go`, `file_spec.go`, `compactor.go`,
`compactor_test.go`, all core tests, and relevant `cmd/ltx` apply, encode, dump,
and verify code. The pinned repository passed `go test ./...`. The apply audit
also traced page writes, decoder finalization, truncation, and post-apply
checksum verification.

For Go v0.4.0 LTX v2: `README.md`, `ltx.go`, `checksum.go`, `encoder.go`,
`decoder.go`, `file_spec.go`, `compactor.go`, their tests, and the relevant
`cmd/ltx` paths. In particular, the audit traced the 100-byte header, four-byte
page header and terminator, independent LZ4 frame per page, page index, trailer,
and logical checksum coverage. That historical source is used only as the v2
import oracle; current output remains governed by the v3 pin.

For TigerStyle: `docs/TIGER_STYLE.md` at the pinned tree.

For Rust: `README.md`, `Cargo.toml`, every file under `src/`, and
`tests/compat.rs` plus its test support. Rust is a secondary design reference
only: it implements an obsolete pre-v3 layout with four-byte page headers,
whole-block LZ4 framing, and no page index.

For `denoland/celld` v0.3.0: `crates/ltx/README.md`, `Cargo.toml`,
`reference/ltx-format.md`, `src/codec.rs`, `src/ltx.rs`, `src/lz4_block.rs`,
`src/compactor.rs`, `src/replica_compactor.rs`, `src/replica.rs`,
`src/wal.rs`, `src/faults_inject.rs`, `tests/differential_xtool.rs`, the
golden-fixture manifest and capture script, the low-level reader assertions,
the Litestream Go WAL testdata under `reference/litestream-go/testdata/`, and
the file-restore integration test. Celld's writer remains a secondary
interoperability and deployment reference rather than the valid-output oracle.
Its immutable golden replica is separately a real-Litestream reader oracle.
The crate pins Go LTX v0.5.2 and provides a byte-exact port of Go's block
compressor plus a dual reader for current flagged raw blocks and legacy
unflagged LZ4 frames. It also validates exact decompressed length, the declared
index size, and the trailer. Its `Vec`, `BTreeMap`, `HashMap`, and
read-to-end design is intentionally not a memory model for this
allocation-free Zig core, and it does not perform Zig's exact one-to-one
index/frame cross-check. This pinned crate is v3-only: it contains no LTX v2
decoder, writer, fixture corpus, or oracle.

The v0.4.0 architecture re-audit covered the same production modules. It found
no new LTX wire profile. Relevant deployment changes are a tail-shaped WAL
resume reader, reusable restore plans with bounded concurrent downloads, and a
single-request `has_any_object` startup probe. Its object client still formats
`litestream-timestamp` as RFC3339Nano; it also permits an ambient AWS credential
chain when explicit keys are empty, which Zig deliberately does not import.
The v0.4.0 tree removed the earlier golden fixtures and most crate-local tests,
so the immutable v0.3.0 fixture pin remains the interoperability reference while
v0.4.0 informs resource and controller design.

The M7 read-path re-audit confirmed that the pinned v0.4.0
[`ReplicaClient`](https://github.com/denoland/celld/blob/a52f9905425bc41134d817694bdc2c50bcc5e856/crates/ltx/src/client/mod.rs#L46-L49)
still exposes `open_ltx_file` as a complete `Vec<u8>` and its
[`object-store adapter`](https://github.com/denoland/celld/blob/a52f9905425bc41134d817694bdc2c50bcc5e856/crates/ltx/src/client/object_store.rs#L692-L708)
materializes the complete response. Its
[`restore`](https://github.com/denoland/celld/blob/a52f9905425bc41134d817694bdc2c50bcc5e856/crates/ltx/src/replica.rs#L565-L595)
then collects the planned objects as `Vec<Vec<u8>>` before rebuilding the image.
That remains useful orchestration evidence but is intentionally not Zig's
fixed-memory model. Zig instead places one exact positional-read port at the
object seam and adapts it to the unchanged sequential codec reader with
caller-owned windows. Amazon S3's official `GetObject` documentation limits a
request to a
[`single range`](https://docs.aws.amazon.com/AmazonS3/latest/API/API_GetObject.html#AmazonS3-GetObject-request-header-Range),
and its range example shows
[`206 Partial Content` with `Content-Range`](https://docs.aws.amazon.com/AmazonS3/latest/API/API_GetObject.html#API_GetObject_Example_13).
The official
[`SigV4` GET example](https://docs.aws.amazon.com/AmazonS3/latest/developerguide/sig-v4-header-based-auth.html#example-signature-GET-object)
includes `range` in the canonical and signed header sets; Zig adopts that
integrity hardening. These are transport behavior and hardening references
only; M7 does not infer or alter LTX wire semantics.

For Litestream v0.5.16: the release archive manifest, `go.mod`,
`cmd/litestream/restore.go`, `replica.go` restore planning and decode path, and
the pinned `superfly/ltx v0.5.2` reader were checked. The shipped binary is the
deployment oracle; it is not rebuilt with the repository's older Go pin.

For raw-block compression: the current Go oracle pins
`github.com/pierrec/lz4/v4 v4.1.23` with module content hash
`h1:oJE7T90aYBGtFNrI8+KbETnPymobAhzRrR8Mu8n1yfU=`. The files inspected were
`internal/lz4block/block.go`, its tests, and `LICENSE`. Zig ports the fast
compressor's search, table-update, match-extension, and output order exactly;
the independently written Celld port is a second byte-exact reference. The
algorithm is Copyright (c) 2015 Pierre Curto under BSD-3-Clause, retained in
[`LICENSE.pierrec-lz4`](../LICENSE.pierrec-lz4). It remains separate from and
must accompany the project's [MIT License](../LICENSE) where applicable.

## LTX v2 import and migration evidence

The v2 import profile is anchored to
[`superfly/ltx` v0.4.0](https://github.com/superfly/ltx/tree/2af9b0cb7a6eebfb59c2ca76acc4ae3adf4b6a09),
commit `2af9b0cb7a6eebfb59c2ca76acc4ae3adf4b6a09`. Its
[`ltx.go`](https://github.com/superfly/ltx/blob/2af9b0cb7a6eebfb59c2ca76acc4ae3adf4b6a09/ltx.go)
sets `Version = 2` in memory after reading the shared `LTX1` magic; the version
is not serialized. Zig therefore requires explicit `.v2` or `.v3` selection
and never falls back to another layout after a parse error. LTX v1 remains
unsupported.

The v2 wire profile has the same 100-byte header and 16-byte trailer used by
the supported v3 profile, but each page begins with only a four-byte page
number. A four-byte zero page number terminates the page block. The pinned
[`Encoder.EncodePage`](https://github.com/superfly/ltx/blob/2af9b0cb7a6eebfb59c2ca76acc4ae3adf4b6a09/encoder.go#L206-L266)
then writes one independent LZ4 frame per page; the decoder reads exactly one
uncompressed page and consumes that frame's end marker before reading the next
page header. The page index and trailer follow the terminator. The logical file
checksum includes the v2 header, four-byte page headers, uncompressed page
bytes, terminator, index, and post-apply checksum, while physical LZ4 framing
bytes are excluded.

After physical decoding, v2 page events enter the same bounded trust pipeline
as v3: strict page order, snapshot completeness, one-to-one index/frame
correspondence, canonical index varints, trailer fields, configured limits,
logical and database checksums, and exact EOF must all verify before a staged
database image or position may be published. The optional SQLite store
publishes that verified image through the same generation manifest and recovery
protocol used for v3; it does not retain or expose the source wire framing.

Migration compaction carries an explicit version on every input. V2-only and
mixed v2/v3 chains still require exact TXID continuity, enabled-checksum
continuity, and a common checksum mode. Their only supported output is the
current canonical v3 profile. The optional interoperability gate regenerates
the v0.4.0 source fixtures, emits v2-only, mixed v2/v3, and SQLite-image
migrations with Zig, and requires their complete bytes to match independently
constructed `FileSpec` outputs from the current Go pin. Attempting to initialize
encoding or compactor output as `.v2` returns `UnsupportedFormatVersion`. Celld
independently informs v3 compaction and deployment behavior but supplies no v2
implementation or oracle.

## SQLite WAL reader evidence

The `ltx_wal` module ports the pinned Celld crate's `wal.rs`, itself a port of
Litestream v0.5.11 `wal_reader.go` and the `WALChecksum` helper. The Zig port
keeps the byte format, validation order (magic, header checksum, version,
page size), frame salt checks before cumulative checksums, commit-record
promotion with newest-page precedence, final-commit filtering, the salt
census, and the mid-WAL resume that re-reads the previous frame to seed the
running checksum. Two deliberate structural divergences are documented here:

1. **Terminal stops stay distinguishable.** Go collapses a clean end, a torn
   frame, a salt mismatch, and a checksum mismatch into one `io.EOF` sentinel;
   Celld models that sentinel as `WalError::Eof`. Zig reports four terminal
   errors (`WalEnd`, `TruncatedFrame`, `SaltMismatch`,
   `FrameChecksumMismatch`) and records the cause, including the foreign salt
   pair, in a `Stop` value. Scans treat all four as the end of the valid
   region, exactly as upstream does.
2. **No page copy and no hash map.** Frames borrow page bytes directly from
   the caller's WAL slice, and the committed page map uses caller-owned page
   slots, a bounded in-transaction page list, and a dedupe bitmap instead of
   Celld's `HashMap`s. Workspace sizing is checked by
   [`docs/resource-budgets.md`](resource-budgets.md).

The committed fixtures under `tests/fixtures/wal/` are copied verbatim from
that pinned tree: the four Litestream v0.5.11 `wal-reader` testdata WALs and
the golden `sample.wal` captured by SQLite 3.51.0. Every asserted frame fact
in `tests/wal.zig` is a ported Litestream or Celld known answer; the page map
is additionally cross-checked against an independent structural reference
implementation in the test file, and the Go `BadHeaderVersion` vector pins the
big-endian checksum algorithm (`0x157b2092`, `0xbbf8341d`). Mutations and the
native fuzz corpus reuse these fixtures; see
[`tests/fixtures/wal/README.md`](../tests/fixtures/wal/README.md).

## Compaction evidence

The pinned Go
[`Compactor.Compact`](https://github.com/superfly/ltx/blob/8cb8f8ebaf8f57c9b0e1041a27d5444032ea0643/compactor.go#L79-L144)
reads headers in caller order, takes page size, minimum TXID, and pre-apply
checksum from the first header, and commit, maximum TXID, and timestamp from the
last. It omits WAL offsets, WAL sizes, salts, and node ID from the new header, so
canonical encoding zeros them. Its
[`writePageBlock`](https://github.com/superfly/ltx/blob/8cb8f8ebaf8f57c9b0e1041a27d5444032ea0643/compactor.go#L146-L227)
chooses the newest buffered occurrence of each lowest page number and skips
pages beyond the final commit. It closes every decoder before closing the
encoder, but pages can already have reached the writer when a late verification
fails. Zig adopts these merge and output-header semantics and makes the
scratch-output requirement explicit.

Go's default range predicate
[`IsContiguous`](https://github.com/superfly/ltx/blob/8cb8f8ebaf8f57c9b0e1041a27d5444032ea0643/ltx.go#L627-L633)
allows an overlapping next range as long as it advances the maximum, does not
compare database checksums, and can be disabled entirely with
`AllowNonContiguousTXIDs`. Zig instead requires
`next.MinTXID == previous.MaxTXID + 1`, requires the enabled checksum chain to
match, requires one checksum mode for the full input set, and exposes no gap or
overlap repair switch. That stricter contract prevents a compacted file from
hiding missing or divergent history.

Celld's low-level
[`compactor.rs`](https://github.com/denoland/celld/blob/89e4ffc53a14ecb496d2ca5014ff9d19b0061ad9/crates/ltx/src/compactor.rs#L88-L172)
independently confirms the first/last header selection, default-zero remaining
header metadata, newest-page precedence, and final-commit cutoff. Its
[`compactor tests`](https://github.com/denoland/celld/blob/89e4ffc53a14ecb496d2ca5014ff9d19b0061ad9/crates/ltx/src/compactor.rs#L242-L297)
exercise both newest-page selection and dropping a page after shrink. Celld's
storage-level
[`replica_compactor.rs`](https://github.com/denoland/celld/blob/89e4ffc53a14ecb496d2ca5014ff9d19b0061ad9/crates/ltx/src/replica_compactor.rs#L94-L217)
adds file-count and input-byte planning bounds, emits no-checksum compacted
levels, rejects gaps or overlaps during level verification, and deliberately
does not delete source files. Zig's `Compactor` remains the lower-level codec
merge: it does not copy Celld's allocation model, select levels, delete files,
or publish storage state.

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

## Real Litestream capture evidence

Celld's immutable
[golden manifest](https://github.com/denoland/celld/blob/89e4ffc53a14ecb496d2ca5014ff9d19b0061ad9/crates/ltx/tests/fixtures/golden/MANIFEST.md)
records a replica tree produced by `litestream replicate -once` using
Litestream v0.5.11 from commit
`016c368704e63db0088b9b61e2e96c0019f11832` and SQLite 3.51.0. Its
[capture script](https://github.com/denoland/celld/blob/89e4ffc53a14ecb496d2ca5014ff9d19b0061ad9/crates/ltx/scripts/capture-golden.sh)
creates a WAL-mode `kv` table, captures a snapshot, then flushes five distinct
insert/update transactions into five more L0 files. The script restores the
full tree with the real Litestream binary and requires logical equality with
the source database.

The six exact L0 files under
`tests/fixtures/celld_litestream_v0511/replica/ltx/0/` are copied from that
pinned tree. Each uses LTX v3, 4096-byte pages, no database checksums, nonzero
WAL size and salts, and legacy unflagged LZ4 frames. The first is a snapshot at
TXID 1; the remaining files are single-transaction incrementals through TXID 6.
The hermetic staged-apply test pins each artifact SHA-256, every header and
trailer value, and the exact database-image SHA-256 after each prefix. The host
SQLite integration test publishes the same chain through the generation store,
opens the final image using a typed immutable read-only lease, verifies the
expected eight rows, and runs `PRAGMA integrity_check`.

For the import qualification, every prefix was also restored independently
with the checksum-verified official
[Litestream v0.5.11 release](https://github.com/benbjohnson/litestream/releases/tag/v0.5.11);
all six output hashes matched the committed known answers. This external oracle
run is intentionally not part of normal CI.

The outbound qualification follows Celld's
[`D4` compaction test](https://github.com/denoland/celld/blob/89e4ffc53a14ecb496d2ca5014ff9d19b0061ad9/crates/ltx/tests/differential_xtool.rs#L510-L585):
a current flagged L1 file covers a prefix, legacy unflagged L0 files retain the
tail, and a real Litestream reader must restore the mixed plan. Zig compacts
the captured TX1–TX4 inputs under limits of four inputs, 20 aggregate decoded
page events, and five output pages. The output is published only after complete
verification. The pinned Go oracle independently compacts the same four input
files with `HeaderFlagNoChecksum`, byte-compares the entire output, requires
the current flagged page representation, and decodes the exact TX4 image hash
`27d2e8ad59731445c4798eec1c76146e85bd931383728d89fbd96f91d97b0f6a`.

A fourth scenario covers the producer side end to end: the tool builds a
real database through `ltx_capture` (a snapshot, an incremental, a
session-initiated passive checkpoint, and a post-checkpoint incremental),
checkpoints the live database, and requires Litestream v0.5.16 to restore
the captured tree to a file byte-identical (SHA-256) to the live image that
also answers queries read-only with the captured rows.

The deployment gate places that Zig file at L1 for TX1–TX4 and retains the
unaltered legacy TX5 and TX6 objects at L0. The checksum-verified official
[Litestream v0.5.16 release](https://github.com/benbjohnson/litestream/releases/tag/v0.5.16)
must restore both the TX4 boundary and the final TX6 image. Their SHA-256 values
are respectively the TX4 hash above and
`ee705e74c9788b64f5dc63b9c3dc028ae05aae34f240bad1362d9436c65150e0`;
the final database must also pass full SQLite integrity and contain the exact
eight captured rows. The official archive SHA-256 values used by release and
CI qualification are:

- Linux x86_64: `9e29112380a942e4a62ee07773684396cb8b308dc4d67e130bef41f75e937f0a`
- Linux arm64: `678022e4103145302598e35d37f8718392d42e153feeb1e2d4a64dd0cd3aaf10`
- macOS x86_64: `eb554b93c9e2833351b017707e9ba5ac97ffd91d07e8b8b836b3ca7661399c36`
- macOS arm64: `3e64028ff3522caca7a5ab67244e0373b25f3db68b6e25cac0056bf71c30c337`

The published `checksums.txt` itself has SHA-256
`074cd89d41b46561c8c087d2728842dad32356c4192171c2488d3eff03a9f317`.
The Linux x86_64 archive is fetched and checked in hosted Linux CI and the
pinned `act` rehearsal. Normal tests remain hermetic; they apply the identical
Zig L1 plus legacy L0 sequence through `StagedApplier` and pin the TX4, TX5,
and TX6 database hashes without spawning Litestream.

Celld's
[reader assertions](https://github.com/denoland/celld/blob/89e4ffc53a14ecb496d2ca5014ff9d19b0061ad9/crates/ltx/src/ltx.rs#L578-L614)
and
[file restore test](https://github.com/denoland/celld/blob/89e4ffc53a14ecb496d2ca5014ff9d19b0061ad9/crates/ltx/tests/integration_file.rs#L271-L315)
provide upstream context for the same corpus. This evidence qualifies reader
and apply compatibility with a real capture; it does not turn the normal test
suite into a Litestream build, validate live follow mode, or replace the
separate checked-current-writer, sparse-transition, growth, shrink, and
crash-publication tests.

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

## Replication-layer evidence

The `ltx_wal`, `ltx_object`, `ltx_replica`, and `ltx_capture` modules port
the pinned Celld crate's replication layers. Naming (`parse_txid` accepts
exactly sixteen hex digits in either case, the filename codec requires the
lowercase `.ltx` extension, filesystem levels are decimal while object levels
are four hex digits), the compaction ladder (L0 immediate, then 30 seconds,
5 minutes, 1 hour, snapshot level 9, interval boundaries truncated), and the
restore planner (newest qualifying snapshot anchor, per-level cursors
extending the longest contiguous range, candidate preference by reach, then
coverage, then level, then timestamp, tail-contiguity rejection for latest
restores) follow Celld's `lib.rs`, `compaction_level.rs`, and `replica.rs`
(`calc_restore_plan`) exactly, with ported planner truth-table tests.

The compaction planner follows Celld's `replica_compactor.rs`: the
destination's maximum plus one is the required continuation TXID, the source
prefix is bounded by file count and aggregate bytes, and gap repair is left
to the codec compactor. `ltx_capture` follows the `db.rs` capture path at
snapshot/incremental/fallback granularity: one TXID per sync batch, the
no-checksum L0 profile, Litestream control tables, a checkpoint-blocking read
lock, DB-file page backfill, and snapshot fallback whenever the WAL segment
salts stop matching the captured segment. It now also implements seeded
mid-WAL resume, byte-, age-, and frame-count checkpoint tiers,
restored-position seeding, and crash-replay continuation. Celld's writer
barrier is deliberately not ported: `ltx_capture.Session` is the single writer
for its database, so the host schedules capture without a second
writer-admission mechanism.

The `ltx_object` filesystem backend writes the Litestream replica tree
(`<root>/ltx/<level>/<min>-<max>.ltx`) with temp-write, sync, and rename
publication, matching Celld's `client/file.rs`; its backend-agnostic
conformance suite plays the role of Celld's `run_client_suite`. The
`ltx_s3` backend implements the same contract with path-style or virtual-host
AWS Signature Version 4 requests, the four-hex level layout of Litestream's
object-store replica, `ListObjectsV2` with prefix scoping and `start-after`
seeking, TLS with a custom or system CA, conditional create and ETag-matched
replacement, bounded retry of idempotent requests, transactional writer
sessions with automatic single-or-multipart publication, and the
`litestream-timestamp` object metadata header. Its signing
decisions — strict AWS URI encoding with uppercase percent escapes in
canonical query values, the payload hash covering every request, and 204
accepted for deletes — are verified against isolated real MinIO lanes for
plain HTTP, TLS, and supported virtual-host addressing by the
`s3-integration` gate rather than by a Zig-only round trip.

## Compatibility decisions and disagreements

The current Go encoder and its tests are the valid-output oracle. The Zig
decoder deliberately rejects malformed files that the Go decoder happens to
accept. These are hardening differences, not silent reinterpretations.

1. **Version selection.** The Go README correctly says v2 and v3 both use
   `LTX1` and need out-of-band version selection. `NewDecoder`, however, takes
   no version and each historical `Header.UnmarshalBinary()` assigns that
   checkout's compiled-in version from magic alone. Zig decoders, staged
   appliers, and compaction inputs require an explicit `.v2` or `.v3`. Encoding
   and compactor output accept only `.v3`; the library never guesses or retries
   another version.

2. **Section count.** Both supported Go profiles contain a header, page block,
   page index, and trailer. The v0.4.0 README and current `CLAUDE.md` each still
   describe three sections and omit the index. Zig requires the four-section
   structure for both versions.

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

15. **Compaction continuity and mode.** Go's compactor accepts overlapping
    advancing TXID ranges, does not compare adjacent database checksums, and
    offers a non-contiguous rebuild switch. Zig compaction requires exact TXID
    and enabled-checksum continuity with one checksum mode. It will not use
    compaction as implicit history repair.

The unflagged v3 LZ4-frame encoding was introduced with v3 and later replaced
without a version bump. Two fixtures from the last historical writer commit
`133c1b1dba55dfb8033affedb3d400aaa3d8b807` exercise compressed and stored
blocks. Frame descriptor and physical payload bytes are excluded from LTX's
logical file checksum, while the decompressed page and LZ4 XXH32 content
checksum are verified.

## Fixture provenance

The per-fixture generation command, semantic header/trailer values, and hashes
are catalogued in [`tests/fixtures/README.md`](../tests/fixtures/README.md).

The LTX v2 fixtures were generated with the v0.4.0 pin through
`tools/v2_fixturegen`; the module and its LZ4 dependency are checksum-locked.
Each binary has a reviewed hex mirror. The primary
`go_v2_mixed_snapshot.ltx` fixture covers compressed and stored LZ4 frames in
one snapshot, while the remaining fixtures cover an empty snapshot, a valid
empty SQLite image, contiguous incremental application, no-checksum mode, and
maximum-size pages around the SQLite lock page. Their SHA-256 values are:

- `go_v2_mixed_snapshot`: `e07e756bf683ef73eb0628177baa8f3a64f59bfbd162957189b626f1331e2eae`
- `go_v2_empty_snapshot`: `1f518147c9c690b0494d6a9c9eb6884f6131bd6e27c739bb4fcc2f9db4971088`
- `go_v2_sqlite_empty`: `263808f41dda5869000e8b722efd1e8d866c6a5dbde594b4b8efbd226f35e09a`
- `go_v2_incremental`: `f960103ca1bf1df2475d4f9a229c7863949f9c4394b35096ae90a257f15e5224`
- `go_v2_no_checksum`: `76b3dfdaa958ad939f9adf4a2e22563452eb8480a006883a995c9cfce775d966`
- `go_v2_near_lock_page`: `35a89b6af9e8f5b29377ad5e904444eb62cef5cf87ae8a512aa400b5a3058e30`

These fixtures are import known answers. They do not make v2 an output target.
The optional migration gate requires v2-only and mixed inputs to produce the
same 736-byte canonical v3 object as an independently constructed current-Go
`FileSpec` (SHA-256
`0a1686e10066a7df8c9e5032054e668d5afdff07ad9dae4edbeaa5f1fa4b45d3`).
It also migrates the valid SQLite fixture to a 233-byte current v3 object
(SHA-256
`18cd3220519ab8c75cd6f44b8d96dc71bf8e21335c3ad4f5462adc71b53a8e4c`)
and checks the decoded database hash with current Go. Litestream v0.5.16 is not
used for this checksummed object because its restore path forces no-checksum
mode while retaining the nonzero post-apply checksum; weakening the migration
would violate the wire contract. The pinned Celld corpus contains no v2
artifact.

The current Go v3 fixtures in `tests/fixtures/` were generated with the pinned
Go `NewEncoder`, directly or through `FileSpec.WriteTo`. The SHA-256 values of
the binary artifacts are:

- `go_v3_snapshot_zero_page`: `7ab2cbb91c15c977abcb7256ac471ee1f4f78343d16b1bacd55edd3d2d930e4a`
- `go_v3_empty_snapshot`: `b270619913b21cecb628827c679749ae6277159391ac0223762f408f57ff7287`
- `go_v3_incremental`: `3a5f87b53d70343c7e19d760b7ff2536b61b229673ae832af15bcf8d18966956`
- `go_v3_no_checksum`: `3c27d6dbb89142fd4054f80d3c4a84027346e71b6dd2d7a87e096359aade7f89`
- `go_v3_near_lock_page`: `e72968228256e29ecb024f0e29a056fbf0ee2c872f7c2589f8bb96901c3f246e`
- legacy unflagged fixture: `cebdc979fea5b00f51eacdcdeef579f6b87a5b5fb901f4fb952d857eef19da1f`
- legacy mixed fixture: `42c81f74ae54b11cf22768223b99a6c2f271e06559ccb619bc8b553533fcb2c5`
- `celld_v052_two_page_snapshot`: `b7c4c3d21a1c009c297934723f737199cbe392164a95f05a2a3763dda059eecb`

The real Litestream capture's six artifact hashes and six prefix database-image
hashes are catalogued beside the corpus in
[`tests/fixtures/celld_litestream_v0511/README.md`](../tests/fixtures/celld_litestream_v0511/README.md).
Those files are immutable captured input, not output from either local fixture
generator. The binaries are mechanically materializable from reviewed hex
mirrors, and CI's separate `check-fixtures` gate requires every pair to match.
Normal tests directly embed the checked-in binaries and never build or invoke
Litestream.

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

The Zig compaction fixture generator emits three transient interoperability
vectors. `merge` compacts three exact checksummed transitions, selects newer
versions of pages 1 and 2, drops pages 3 and 4 at final commit 2, carries the
last timestamp and checksum, and proves that nonzero source WAL and node
metadata becomes zero. `deletion` compacts a one-page snapshot followed by an
exactly contiguous incremental deletion to commit zero, yielding no pages and
the flagged empty-database checksum. `no-checksum` compacts two exact
incremental transitions in the mode emitted by Celld's storage-level compactor;
the Go oracle explicitly sets `Compactor.HeaderFlags` because Go does not derive
the output mode from its input headers. These files are generated during the
interop build rather than treated as committed Go-derived corpus.

The deterministic valid-chain matrix broadens that differential check without
turning generated outputs into committed corpus:

| Case | Transition shape | Decoded database SHA-256 |
| --- | --- | --- |
| `checked-grow-512` | Three checksummed TXIDs grow from two to five 512-byte pages, then update two pages | `c89c89ca0c8c8a5ad990add46f40c64237cc847535b7c46a1338671f24727203` |
| `checked-sparse-shrink-4096` | Three checksummed TXIDs sparsely update five 4096-byte pages, then shrink to three | `748180e5b2dcef3c390c2b9b26700b20df220c43455bc52f75d41e769b6f7adc` |
| `no-checksum-max-page-shrink-65536` | Two no-checksum TXIDs shrink two maximum-size pages to one updated page | `1f2d41b212c74e121e69ba1f71cdf254ce7b478dfb675bca590a1bb9c952354f` |
| `checked-delete-1024` | A three-page checksummed snapshot followed by a contiguous deletion | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` |
| `legacy-current-512` | The committed legacy unflagged zero-page snapshot followed by a current incremental | `a84f98fa7bc9cfbb6ee11fc4eb67c730d9648d3a32a4933b289d5cc28fc72865` |

Hermetic Zig tests build the expected image directly, apply each source in
order, compact the chain, and apply that output independently. All three paths
must agree byte for byte and with the hash above. Every fresh source has
nonzero WAL offset, WAL size, salts, and node ID; every compacted header zeros
those source-local fields. Page-bearing outputs use the current flagged
raw-LZ4 profile, including the output whose first input is historical
unflagged v3.

The pinned Go verifier separately constructs the current source files, reads
the committed legacy fixture where applicable, and byte-matches all 12 Zig
source files before running `ltx.NewCompactor` over those bytes. Each complete
Zig output must be byte-identical to Go before Go decodes and checks its
database SHA-256. The checksum-verified Litestream v0.5.16 binary
also restores `no-checksum-max-page-shrink-65536` as a standalone L1 object
and reproduces its exact hash. The same harness requires a bounded rejection
for `checked-grow-512`: Litestream forces no-checksum compaction while retaining
that checksummed file's nonzero post checksum. This is a Litestream v0.5.16
mode-conversion limitation, not a Zig/Go output mismatch. Both payloads are
deterministic byte patterns rather than SQLite-generated pages, so these probes
qualify LTX deployment reading, not SQLite database validity.

`mise exec -- zig build interop` performs the snapshot verification plus all
synthetic and real-capture compaction checks from the build graph. For
compaction, the exact pinned Go module independently reconstructs or reads the
inputs, runs `ltx.NewCompactor`, byte-compares the full output with Zig, and
decodes it for semantic checks, including the five-case matrix. `mise exec -- zig build litestream-interop
-Dlitestream=/absolute/path/to/litestream` adds the real v0.5.16 deployment
reader over the mixed-level tree and selected matrix probes described above.
The Go module uses the
checksum-locked pseudo-version resolving exactly to the recorded commit;
unlike the normal test suite, the interop gates may require downloaded tools
or modules.
