# Fuzzing

The fuzz suite uses Zig 0.16's native structured-input fuzzer. Its checked-in
corpora run during every `zig build test`; mutation starts only when the build
is passed `--fuzz`.

Run the corpus and deterministic mutation smoke tests with:

```sh
mise exec -- zig build fuzz -Doptimize=ReleaseSafe
```

Run the same bounded search as CI with:

```sh
mise exec -- zig build fuzz --fuzz=10K -Doptimize=ReleaseSafe --seed 0
```

Omitting the iteration count starts an open-ended session and enables Zig's
fuzzing web interface:

```sh
mise exec -- zig build fuzz --fuzz -Doptimize=ReleaseSafe
```

The native fuzzer runs host binaries and is supported on the 64-bit Linux and
macOS hosts used by this project. CI runs the bounded mutation step once on
Linux; both operating systems still replay every corpus input in the normal
release-safe test step.

## Properties and bounds

The whole-file decoder property accepts at most 1,024 hostile bytes, eight
pages, 4,096 bytes per page, and 4,200 compressed bytes per page. It compares
the complete result of contiguous and 1..64-byte transport reads: event order,
page metadata and checksums, exact rejection error and bytes consumed, terminal
state, and verified header/trailer values must agree. Returned pages are also
checked independently for commit, lock-page, and ordering rules; verified
snapshot page checksums must fold to the trailer checksum. Every failure must
poison the decoder, every success must consume exact EOF, and both paths must
terminate within the fixed event budget.

The deterministic companion test replays all seven committed fixtures whose
pages fit that bound through several chunk sizes. It also checks every strict
prefix and one fixed single-bit mutation per byte. The 65,536-byte near-lock
fixture remains covered by its byte-exact interoperability test; its raw
compressed page is included in the LZ4 corpus.

The compactor property accepts at most 1,024 hostile bytes as either one input
or two halves. Every processing result must reach exactly one terminal state:
failure poisons the compactor and success must produce an output whose decoded
`VerifiedLTX` exactly matches the returned value. A second `compact()` call is
always rejected. Separate deterministic tests cover aggregate page bounds,
cross-workspace aliasing, and unverified partial output after a late checksum
failure.

The raw LZ4 decoder property accepts at most 1,024 compressed bytes and chooses
from fixed output sizes spanning 0 through 65,536 bytes. Differently poisoned
successful outputs must become identical, and malformed inputs must return the
same exact error and partial writes when replayed with the same poison. Guard
regions on both sides of every output stay unchanged.

The raw LZ4 compressor property accepts at most 4,096 bytes. It verifies that
the fast encoder is deterministic after two different workspace poison
patterns, that both fast and exact-capacity literal encodings round trip, and
that a buffer one byte below the literal bound fails without modifying output.
The existing exact tests retain maximum-page and upstream byte-compatibility
coverage outside this mutation bound.

## Corpus maintenance

Corpus entries are Zig `Smith` decision streams, not bare LTX or LZ4 files.
They encode each selected integer before the length-prefixed byte slice. Keep
the seed helpers in `tests/fuzz.zig`, `tests/compactor.zig`, and
`tests/fuzz_lz4.zig` as the canonical way to construct them.

Zig reports learned and crashing inputs under `.zig-cache/f/`. Minimize and
replay a failure, then promote it either to the appropriate checked-in corpus
or to a focused regression test with a descriptive assertion. Cache artifacts
themselves are not source files and must not be committed.
