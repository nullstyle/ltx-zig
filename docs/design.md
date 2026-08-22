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
repair is attempted.

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
make that status explicit. A future apply layer must stage pages and publish
them atomically only after the terminal verified event. This library does not
perform authoritative in-place SQLite mutation.

## State machines

The decoder has one central `next()` operation:

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
written. There is no ambiguous `close()` operation.

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

Legacy frame decoding reuses the compressed workspace for only the declared
block payload. Its fixed descriptor, block word, and footer stay inline, so no
extra frame-sized allocation or read-ahead is needed. The configured compressed
page bound is checked before the payload is read.

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
`Decoder` and `Encoder` are stateful, single-owner values: do not copy them or
interleave operations through copies after initialization. Copies would share
the transport context and workspaces while duplicating stream state.

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

## Checksum model

LTX uses Go-compatible CRC-64/ISO. A page checksum covers the big-endian page
number followed by page data and sets bit 63. A database checksum is the XOR of
flagged page checksums with bit 63 restored after each update. The SQLite
pending-byte lock page at `0x40000000 / page_size + 1` is excluded. The
checksummed empty database value is the flag alone,
`0x8000000000000000`, matching the current encoder and wire tests.

The file checksum is logical rather than physical. It covers the header; each
page header; each current-format size prefix; decompressed page bytes instead
of compressed payload; the page sentinel; index entries, terminator, and
index-size field; and the post-apply checksum. Legacy LZ4 descriptor, block,
end-marker, and XXH32 bytes are physical framing and are excluded. The stored
file-checksum field is also excluded.

## Error taxonomy

Errors remain distinguishable by cause:

- configuration/workspace: `InvalidLimits`, `WorkspaceTooSmall`,
  `WorkspaceAliasing`;
- configured bounds: `InputLimitExceeded`, `PageLimitExceeded`, and related
  limit errors;
- transport: `InputFailure`, `OutputFailure`, `TruncatedInput`;
- malformed structure: invalid magic, fields, order, varints, index, trailer,
  or trailing bytes;
- unsupported features: `UnsupportedFormatVersion`,
  `UnsupportedPageEncoding`;
- integrity: `ChecksumMismatch`, `SnapshotChecksumMismatch`,
  `LZ4ContentChecksumMismatch`;
- transition semantics: `NonContiguousTransition`, `DivergentHistory`;
- API misuse or poisoned terminal state: `InvalidState`.

Malformed external input returns errors; assertions are reserved for internal
invariants and caller-side programming contracts already established by types
or initialization.

## Future layers

A SQLite apply layer will consume unverified page events into private staging
and commit only after `VerifiedLTX`. Compaction will sit above the codec and
produce a new, independently verified transition. Storage adapters, encryption,
Tigris transport, actor lifecycle, and scheduler coordination remain outside
this focused library.
