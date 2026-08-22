# Design

## Position transitions

The central value is a transition between replication positions. A `Position`
contains a `TXID` and the database checksum after that TXID. A structurally
valid header identifies the pre-apply position as `(MinTXID - 1,
PreApplyChecksum)`. A successful terminal operation returns a `VerifiedLTX`;
its position methods derive the trusted pre- and post-apply positions from the
validated header and trailer rather than storing duplicate values that could
disagree.

`VerifiedLTX.check_contiguous()` requires exact TXID continuity. When database
checksums are enabled it also requires checksum equality; matching TXIDs with a
different checksum returns `error.DivergentHistory`. No automatic history
repair is attempted. `StagedApplier` makes replacement explicit: `.contiguous`
always performs that check, while `.replace_snapshot` bypasses it only for a
snapshot. Incrementals are always contiguous and require the current database's
tracked page size to match the validated LTX header.

## Trust boundary

Input bytes are hostile. Trust increases in these stages:

1. raw transport bytes;
2. a decoded and validated `Header` event;
3. ordered `UnverifiedPage` events whose frame structure is valid;
4. a page index cross-checked against every observed physical frame;
5. a validated trailer and matching logical file checksum;
6. snapshot database-checksum verification, when applicable;
7. the terminal `VerifiedLTX` value.

Pages necessarily arrive before the file checksum. Their type and event name
make that status explicit. `StagedApplier` copies them into backend-owned
private storage, waits for the terminal verified event, then verifies the
completed staged database checksum before requesting one atomic publication.
It never performs authoritative in-place SQLite mutation.

`Compactor` has the same late-verification constraint across every source. It
may stream selected pages to scratch output before all input trailers and EOFs
are verified. Only a successful terminal `VerifiedLTX` makes that output
publishable; partial output after any error is untrusted and must be discarded.

Format selection precedes this trust ladder. LTX v2 and v3 both start with
`LTX1`, so a caller supplies `.v2` or `.v3` from trusted out-of-band metadata.
The decoder never guesses, retries, or reinterprets bytes under the other
layout. Once selected, both versions pass through the same ordering, index,
checksum, exact-EOF, and terminal-verification requirements.

## State machines

The decoder has one central `next()` operation after explicit v2/v3 selection:

```text
header -> pages -> page_index -> trailer -> verified
   \         \          \          \
    +---------+----------+-----------> failed
```

It emits a validated header, zero or more unverified pages, a page-block
completion event, then one verified terminal result. Any processing error moves
it to `failed`. Calls after `failed` or `verified` return `error.InvalidState`.

The encoder exposes state-specific verbs:

```text
initialized -> pages -> index_written -> trailer_written -> finished
      \           \            \               \
       +-----------+------------+----------------> failed
```

`write_header()`, `write_page()`, and `finish()` reject invalid call order.
`finish()` validates snapshot completeness and checksum contracts before
emitting terminal metadata, then returns a verified description of the bytes
written. Encoding is intentionally v3-only; initializing an encoder with `.v2`
returns `UnsupportedFormatVersion`. There is no ambiguous `close()` operation.

The compactor is a one-shot merge:

```text
initialized -> compacting -> finished
     \             \
      +-------------+-----> failed
```

`compact()` reads oldest-to-newest inputs using each input's explicit v2 or v3
selection, selects the newest occurrence of each page, omits pages beyond the
final commit, terminally verifies every input, and finishes a canonical v3
current-format output. TXID ranges must join exactly; checksummed positions
must also join exactly. A processing error poisons the session even when bytes
have already reached the output transport.

The staged applier is also one shot:

```text
initialized -> staging -> published
     |            |  \
     +----------> failed
                  |
                  +-----> recovery_required
```

It begins private staging only after a validated header and bounded final-image
plan. A successful `begin` normally ends with one successful `publish` or one
infallible `abort`. Ordinary errors poison the session as `failed`. Publication
occurs only after `VerifiedLTX` and the applicable full staged-image checksum
scan.

`ApplyPublishIndeterminate` is distinct because the backend's durable commit
point may have been crossed. The backend ends staging before returning it, so
the applier does not call `abort` and instead becomes `recovery_required`.
Authoritative bytes, page-size metadata, and position must then be resolved by
backend-specific recovery before another apply. Every terminal state rejects
further calls with `error.InvalidState`.

## Memory and transports

The core performs no dynamic allocation. Decoder initialization receives:

- one workspace at least `Limits.max_page_size` bytes;
- one workspace at least `Limits.max_compressed_page_size` bytes;
- a fixed slice with at least `Limits.max_page_index_entries` records.

Encoder initialization receives the compressed-data workspace, a fixed
`LZ4CompressionWorkspace`, and the page-index workspace; the page passed to
`write_page()` is caller owned. The typed LZ4 workspace contains 65,536 `u16`
match positions plus a 2,048-word occupancy bitmap, for a fixed 139,264-byte
(136 KiB) footprint. It is passed by pointer so an `Encoder` cannot silently
copy that storage. Initialization rejects undersized buffers before consuming
or emitting bytes, and rejects every overlap among its three workspaces and a
reported output backing range. `write_page()` likewise rejects page input that
aliases any workspace or reported output storage.

Every raw block is independent. Before any fast-path match-state read, the
encoder clears the occupancy bitmap, so undefined table bytes and prior pages
cannot influence output. The literal fallback does not touch the match state.
When the configured compressed-output cap can hold the canonical LZ4 bound
`n + n / 255 + 16`, the encoder runs the byte-compatible fast compressor used
by the pinned Go and Celld sources. A cap below that bound but at or above the
literal bound selects a deterministic literal-only block instead. This keeps
the configured memory bound authoritative without rejecting an otherwise safe
configuration.

Compaction receives one complete decoder workspace set per input and one
complete encoder workspace set for output. These sets, the mutable
`CompactionInput` slice, and output backing must remain address-stable,
exclusively owned, and mutually non-overlapping for the operation. Immutable
reported reader backings may overlap each other, but not mutable input state,
workspaces, or output. Opaque transport-context extents cannot be inspected and
remain a caller-side lifetime, aliasing, and non-reentrancy obligation. Each
input holds at most one decompressed page while the merge selects the newest
page at the smallest current page number. No page map or materialized database
image is allocated.

LTX v2 and legacy unflagged v3 frame decoding reuse the compressed workspace
for only the declared block payload. Their fixed descriptor, block word, and
footer stay inline, so no extra frame-sized allocation or read-ahead is needed.
The configured compressed page bound is checked before the payload is read.

The index workspace is essential rather than incidental. The encoder must
retain the physical offset and encoded size of every frame until it emits the
trailing index. The decoder retains the same observed values until it can
cross-check the hostile trailing index. A hash map or growing array would hide
allocation and weaken deterministic bounds, so both directions use caller
provided `[]PageIndexEntry` storage.

`Reader` and `Writer` are small callback transports. The reader may return
short reads and supplies a non-consuming exact-end check, so trailer validation
does not consume a byte from the next object in a concatenated stream. The core
bounds progress by the requested byte count and `max_input_bytes`. Transport
failures map to `error.InputFailure` or
`error.OutputFailure`. `SliceReader` and `SliceWriter` are included for memory
buffers. The core imports no filesystem API and does not require libc.

Slice transports publish their backing range so the codec can reject overlap
with workspaces, page input, or output. Custom transport implementers should do
the same when a stable range exists. All codec workspaces must remain live,
address-stable, and exclusively owned until the codec reaches a terminal
state. Transport contexts and any unreported backing storage have the same
lifetime requirement and must remain non-overlapping and non-reentrant; zero
from `read_fn` means permanent EOF.
`at_end_fn` must be non-consuming and report the exact end of this one LTX
object, which requires known-length framing or buffering for a shared stream.
`Decoder`, `Encoder`, `Compactor`, and `StagedApplier` are stateful,
single-owner values: do not copy them or interleave operations through copies
after initialization. Copies would share transport, workspace, and backend
contexts while duplicating state-machine state.

`StagedApplier` owns its decoder and reuses the page workspace for its final
database scan after decoding finishes. Its backend is synchronous and
non-reentrant. Page callbacks must copy page bytes before returning, because
the next codec operation overwrites them. A reported backend backing range is
checked for overlap with input and all codec workspaces. The apply core remains
storage-neutral, performs no dynamic allocation, and requires no libc. Because
the core cannot inspect an adapter's storage directly, `begin` reports tracked
page-size metadata for the core to compare before staging an incremental. The
backend separately rejects incompatible physical layout not represented by
that metadata, including when database checksums are disabled.

## Limits and arithmetic

There are no implicit core defaults. `Limits` bounds physical input and output
bytes, pages, page size, compressed size, index bytes, index entries, bytes per
varint, and TXID span. The encoder requires `max_compressed_page_size` to hold
the worst-case literal block for `max_page_size`; reaching the slightly larger
canonical fast-compressor bound is optional. Configured workspace maxima are
converted to `usize` only at slice boundaries. Offset and length additions use
checked arithmetic before transport access. The encoder preflights a complete
page frame and the complete sentinel/index/trailer section against configured
bounds before the first write of either logical section. Transport failures
can still be partial. Loops are bounded by a configured maximum, an input slice
length, or a fixed wire width.

`ApplyLimits` separately bounds final database pages and bytes. Both are
checked after the header validates and before backend staging begins. The
post-decode database scan is bounded by the verified commit page count and
holds only one page at a time.

`CompactionLimits` separately bounds the input count and aggregate decoded page
events. The aggregate includes duplicate and final-commit-truncated pages, so
discarded work cannot escape the configured bound. Normal `Limits` still
applies independently to every decoder and to the output encoder; consequently,
the combined first-to-last output TXID span must also fit
`Limits.max_transaction_span`.

## Checksum model

LTX uses Go-compatible CRC-64/ISO. A page checksum covers the big-endian page
number followed by page data and sets bit 63. A database checksum is the XOR of
flagged page checksums with bit 63 restored after each update. The SQLite
pending-byte lock page at `0x40000000 / page_size + 1` is excluded. The
checksummed empty database value is the flag alone,
`0x8000000000000000`, matching the current encoder and wire tests.

The file checksum is logical rather than physical. It covers the header; each
version-specific page header; each current v3 size prefix; decompressed page
bytes instead of compressed payload; the version-sized page sentinel; index
entries, terminator, and index-size field; and the post-apply checksum. V2 uses
four-byte page headers. Both v2 and legacy unflagged v3 exclude the LZ4
descriptor, block, end-marker, and XXH32 bytes as physical framing. The stored
file-checksum field is also excluded.

For each checksummed apply, the applier independently scans the private final
database image and compares its rolling checksum with the verified trailer.
This catches incorrect base-image construction and missed page writes before
publication. Exact final length remains part of the trusted `begin`/`publish`
backend contract because the scan reads exactly the planned pages. The SQLite
lock page is excluded from that checksum. A snapshot backend nevertheless
zero-fills its entire new image, including the omitted lock page, so no bytes
survive from an older database. No-checksum files skip the database-image scan
but still require their logical file checksum and all structural verification.

## Error taxonomy

Errors remain distinguishable by cause:

- configuration/workspace: `InvalidLimits`, `WorkspaceTooSmall`,
  `WorkspaceAliasing`;
- configured bounds: `InputLimitExceeded`, `PageLimitExceeded`, and related
  limit errors;
- transport: `InputFailure`, `OutputFailure`, `TruncatedInput`;
- malformed structure: invalid magic, fields, order, varints, index, trailer,
  or trailing bytes;
- unsupported features: `UnsupportedFormatVersion` (including v1 and v2
  encoding), `UnsupportedPageEncoding`;
- integrity: `ChecksumMismatch`, `SnapshotChecksumMismatch`,
  `LZ4ContentChecksumMismatch`, `DatabaseChecksumMismatch`;
- transition semantics: `NonContiguousTransition`, `DivergentHistory`;
- compaction configuration and compatibility: `CompactionInputRequired`,
  `CompactionInputLimitExceeded`, `CompactionPageLimitExceeded`,
  `CompactionPageSizeMismatch`, `CompactionChecksumModeMismatch`;
- staged apply bounds and backend failures: `DatabasePageLimitExceeded`,
  `DatabaseSizeLimitExceeded`, `DatabasePageSizeMismatch`,
  `ApplyBeginFailure`, `ApplyStageFailure`, `ApplyReadFailure`,
  `ApplyPublishFailure`, `ApplyPublishIndeterminate`;
- API misuse or poisoned terminal state: `InvalidState`.

Malformed external input returns errors; assertions are reserved for internal
invariants and caller-side programming contracts already established by types
or initialization.

## Storage boundary and future layers

The optional `ltx_sqlite` adapter implements private filesystem staging and
atomically combines the expected-position comparison, complete-image selection,
page-size metadata, and position advance in one checksummed manifest. It
installs a durable empty manifest before first publication, requires
application-owned SQLite quiescence, and grants immutable read-only active
generations through typed accesses that hold a shared advisory lock across
manifest resolution and connection lifetime. Publication and recovery hold the
same lock exclusively, including through indeterminate recovery. The adapter is
exercised at each durability boundary by a separate crash process. The core
itself remains filesystem- and SQLite-independent. The exact durability and
recovery protocol is in
[`sqlite-store.md`](sqlite-store.md).

LTX v1 and fixed-path publication beneath open SQLite handles remain
unsupported. Fixed-path replacement is unsafe because
SQLite associates journals and WAL state with the pathname, and its Online
Backup API does not preserve exact LTX page-one bytes. The compactor produces a
new independently verified transition but deliberately does not select storage
levels, retire inputs, publish a replica, or coordinate a Litestream process;
its full contract is in [`compaction.md`](compaction.md). Encryption, Tigris
transport, local-writer capture, actor lifecycle, and scheduler coordination
remain outside this focused library.
