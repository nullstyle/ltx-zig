# Compaction

`Compactor` merges a chronologically ordered set of LTX v2 and/or v3 files into
one verified canonical v3 transition without allocating. It is a codec
operation, not a storage-level compaction service: callers still choose files,
provide scratch output, publish the successful result, and retire source files.

## Merge semantics

Inputs are supplied oldest to newest. A successful compaction applies these
rules:

- each input carries an explicit format version; the shared `LTX1` magic is
  never used to infer v2 or v3;
- every input reaches its terminal `VerifiedLTX` result;
- all page sizes and checksum modes match;
- each next `MinTXID` equals the previous `MaxTXID + 1` exactly;
- for checksummed inputs, each next pre-apply checksum equals the previous
  post-apply checksum;
- when multiple inputs contain a page, the newest input's page wins;
- pages above the last input's `Commit` are omitted;
- the output post-apply checksum comes from the last verified input.

There is no overlap acceptance, gap repair, or equivalent of Go's
`AllowNonContiguousTXIDs`. A TXID mismatch returns
`NonContiguousTransition`; a checksummed history mismatch returns
`DivergentHistory`. Mixed checksummed and no-checksum inputs return
`CompactionChecksumModeMismatch`. Consistent no-checksum inputs remain
no-checksum in the output rather than inventing database checksums.

The output header takes `PageSize`, `MinTXID`, and `PreApplyChecksum` from the
first input, and `Commit`, `MaxTXID`, and `Timestamp` from the last. Its checksum
flag is derived from the common input mode. `WALOffset`, `WALSize`, both WAL
salts, and `NodeID` are zero because source-local provenance no longer describes
the merged file; canonical encoding also zeros reserved header bytes. Output
pages use the current flagged raw-LZ4 representation even when an input used v2
framing or the supported legacy unflagged v3 frame profile. The output version
passed to `Compactor.init` must be `.v3`; `.v2` is rejected because the encoder
is deliberately v3-only. Compaction is therefore the supported wire migration
path rather than a v2 re-encoder.

Final commit zero is meaningful. For example, compacting a checksummed snapshot
followed by a contiguous incremental deletion produces a verified empty
snapshot with no pages and post-apply checksum `0x8000000000000000`.

## Initialization and memory

Each `CompactionInput` borrows one reader and the same three workspaces required
by a decoder: page bytes, compressed bytes, and page-index entries. The output
borrows a writer plus the encoder's compressed bytes, fixed
`LZ4CompressionWorkspace`, and page-index entries.

```zig
var inputs = [_]ltx.CompactionInput{
    ltx.CompactionInput.init(
        .v2,
        first_reader,
        first_page_workspace,
        first_compressed_workspace,
        first_index_workspace,
    ),
    ltx.CompactionInput.init(
        .v3,
        second_reader,
        second_page_workspace,
        second_compressed_workspace,
        second_index_workspace,
    ),
};

var compactor = try ltx.Compactor.init(
    .v3,
    codec_limits,
    .{ .max_inputs = 2, .max_total_pages = 8192 },
    &inputs,
    scratch_writer,
    &output_compressed_workspace,
    &output_compression_workspace,
    &output_index_workspace,
);
const verified = try compactor.compact();
```

Every `CompactionInput.init` call requires the source's trusted out-of-band
version, including an all-v3 input set. The output version is selected
separately by `Compactor.init` and must be `.v3`; neither call discovers or
guesses a version from input bytes.

`Limits` applies independently to every input decoder and the output encoder.
`CompactionLimits.max_inputs` bounds the number of sources, while
`max_total_pages` bounds decoded page events across all inputs, including older
versions of a page that are later discarded. The output page-index workspace
must hold every unique emitted page and is also bounded by `Limits`. The
aggregate output range from the first `MinTXID` through the last `MaxTXID` must
fit `Limits.max_transaction_span`, even when every individual input range fits
on its own.

The mutable input slice, all decoder and encoder workspaces, and output backing
storage must remain live, address-stable, exclusively owned, and mutually
non-overlapping until the compactor is terminal. Reported immutable reader
backings may overlap one another, which supports multiple views into shared
input storage. A reported mutable backing may not overlap any reader backing;
neither kind may intersect mutable input state, any workspace, or the output.
`init` checks those reported ranges before consuming or emitting bytes.
Opaque transport contexts expose no extent for the core to inspect, so their
owners must enforce the same lifetime, non-aliasing-with-mutable-storage, and
non-reentrancy requirements. A compactor is stateful and single-owner; do not
copy it or its `CompactionInput` slice after initialization.

`ltx_replica.CompactionJobInput.read_workspace` is a mutable refill window,
not an immutable input backing. The executor therefore checks all active read
windows against one another, source metadata, both control arrays, every
decoder workspace, and active output storage before its first source read.
Whole-object output fallback storage is inactive and excluded when the client
supports transactional writes. Aliased live ranges fail with
`WorkspaceAliasing`. `ObjectReader` also marks the refill window as mutable at
the generic `Reader` seam, so direct core-compactor callers cannot pass an
overlap through the allowance for immutable readers over shared bytes.

## Verification and partial output

Compaction streams pages, so it can write a header and page data before a later
input's index, trailer, checksum, snapshot checksum, or EOF fails. Any processing
error poisons the compactor and `current_state()` reports `failed`; subsequent
calls return `InvalidState`.

Only the `VerifiedLTX` returned by a successful `compact()` authorizes use of
the output. Write into a private buffer or temporary file, discard the entire
partial result on error, and publish only after success. The compactor does not
rename files, update a manifest, delete inputs, select storage levels, or
coordinate SQLite or Litestream processes.

## Interoperability gate

The deterministic fixtures can be written without Go:

```sh
mise exec -- zig build compaction-fixture -Dcompaction-fixture=merge > /tmp/merge.ltx
mise exec -- zig build compaction-fixture -Dcompaction-fixture=deletion > /tmp/deletion.ltx
mise exec -- zig build compaction-fixture -Dcompaction-fixture=no-checksum > /tmp/no-checksum.ltx
```

`mise exec -- zig build interop` performs the stronger optional Go check. The
exact pinned module independently constructs the synthetic inputs, runs
`ltx.NewCompactor`, and byte-compares its output with Zig before decoding and
checking it semantically. The merge case covers three checksummed inputs,
newest-page precedence, final-commit shrinkage, current page flags, and zeroed
source metadata. The deletion case covers a contiguous incremental deletion to
commit zero. The no-checksum case covers the mode emitted by Celld's
storage-level compactor and configures the Go oracle explicitly for that output
mode.

The same gate runs a broader deterministic valid-chain matrix:

| Case | Inputs | Final image |
| --- | ---: | --- |
| Checksummed growth, 512-byte pages | 3 | Five pages after updates at each growth stage |
| Checksummed sparse update and shrink, 4096-byte pages | 3 | Three pages, with newest versions retained below the final commit |
| No-checksum shrink, 65,536-byte pages | 2 | One maximum-size page |
| Checksummed deletion, 1024-byte pages | 2 | Empty database |
| Legacy unflagged plus current, 512-byte pages | 2 | One current updated page |

For every row, hermetic Zig tests compare sequential staged application, an
independent direct image model, and staged application of the compacted output.
The database SHA-256 is pinned. The Go verifier independently rebuilds the
current inputs, uses the committed historical fixture for the legacy prefix,
runs the pinned `ltx.NewCompactor` over the 12 byte-matched Zig source files,
requires complete output byte equality, and decodes the same database hash.
Fresh source headers deliberately contain
nonzero WAL and node metadata; the compacted header must zero those fields.
The legacy/current case additionally proves that a legacy unflagged input is
accepted while every emitted page uses the current flagged raw-LZ4 profile.

The same Go gate also compacts TX1 through TX4 of the immutable real
Litestream capture. It byte-matches the Zig output, requires current flagged
raw-LZ4 pages, and decodes the exact known TX4 SQLite image. For the deployment
boundary, `mise exec -- zig build litestream-interop
-Dlitestream=/absolute/path/to/litestream` requires a binary reporting exactly
v0.5.16. Release qualification and CI use the checksum-pinned official archive.
The harness builds a forced replica plan containing the Zig TX1–TX4 L1 object
and the legacy-frame TX5/TX6 L0 tail, restores at TX4 and TX6, and checks both
database hashes plus final SQLite integrity and rows. Hosted Linux CI extracts
and runs the archive only after verifying its pinned SHA-256. The harness also
restores the matrix's no-checksum maximum-page output as a standalone L1 object
and requires its exact image hash. Its checked-growth probe is a bounded
expected rejection: Litestream v0.5.16 forces Go compaction to no-checksum mode
but retains the input's nonzero post-apply checksum, producing an invalid
combination. The Zig output remains byte-identical to the pinned Go compactor
in its checksummed mode. These matrix payloads are synthetic byte-pattern
database images, so neither probe is a SQLite-validity claim. Normal Zig tests
do not run Go or Litestream and never access the network; they reproduce the
same mixed-representation chain with the bounded staged applier.

The v2 input profile is anchored to `superfly/ltx` v0.4.0 at commit
`2af9b0cb7a6eebfb59c2ca76acc4ae3adf4b6a09`. The interoperability gate migrates
v2-only, mixed v2/v3, and valid SQLite-image inputs and requires complete output
byte equality with independently constructed current-Go canonical v3 files.
Celld provides secondary v3 compaction and deployment evidence but no v2
implementation. The pinned source evidence and deliberate strictness
differences are recorded in [`upstream.md`](upstream.md).
