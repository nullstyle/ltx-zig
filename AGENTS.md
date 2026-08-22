# Engineering rules for ltx-zig

- Target and test with Zig 0.16.0 through `mise exec -- zig`.
- Preserve the public import name `ltx` and keep the core free of libc.
- Treat pinned `superfly/ltx` encoder output and tests as the wire oracle. Record
  upstream changes in `docs/upstream.md`; never infer v2/v3 from `LTX1`.
- Treat the pinned `denoland/celld` LTX crate as a secondary interoperability
  and deployment reference, not a replacement for the Go oracle.
- Safety, performance, then developer experience. Use explicit control flow,
  no recursion, and a fixed bound for every loop and resource.
- Core code must not allocate after initialization. Require caller-owned,
  fixed-capacity workspace; never introduce a growing array or hash map for the
  page index.
- Use explicit-width domain and wire values. Restrict `usize` to slice/API
  boundaries and check conversions and offset/length arithmetic.
- Decode and encode fixed-width fields explicitly in big-endian order. Never
  overlay a packed Zig struct on hostile bytes.
- Assertions are for programmer errors and established internal invariants.
  Return specific errors for malformed input, configured limits, unsupported
  features, transport failures, and checksum mismatches.
- A page event is unverified. Never expose a trusted post-apply position before
  the full index, trailer, checksum, snapshot checksum, and EOF are verified.
- Apply only through private backend staging. For checksummed files, scan the
  complete staged database before an atomic expected-position, image, and
  position publication; require incremental page-size compatibility even
  without database checksums, and abort without durable mutation on failure.
- Keep state transitions centralized and poison a decoder, encoder, compactor,
  or staged applier after a processing failure. Use `finish()`, not an
  ambiguous `close()`.
- Keep functions near or below 70 lines, use `snake_case`, capitalize acronyms
  such as `TXID`, and suffix quantities with units such as `_bytes` or `_count`.
- Canonical encoding zeros reserved bytes, uses the pinned byte-compatible fast
  raw LZ4 compressor with explicit caller-owned match state, emits pages and
  index entries in strict order, and is deterministic. Preserve its
  `LICENSE.pierrec-lz4` attribution.
- Test positive and negative boundaries. Maintain independent Go-derived known
  answers; a Zig round trip alone is not an interoperability test.
- Compact only fully verified, oldest-to-newest inputs with one checksum mode.
  Require exact TXID and enabled-checksum continuity; do not add overlap or gap
  repair. Newest pages win, the final commit bounds output, and compacted WAL,
  salt, and node metadata is zero. Bound input count and aggregate decoded page
  events with caller-owned workspaces. Publish output only after `compact()`
  returns `VerifiedLTX`; discard any partial output after an error.
- Preserve decoding of the canonical legacy unflagged v3 LZ4 profile as well
  as current flagged blocks. V2 and fixed-path replacement beneath open SQLite
  connections are not currently supported. The optional
  `ltx_sqlite` store requires a host-owned quiescence gate, a durable empty
  manifest before first slot creation, and typed active-generation access that
  holds the shared store lock until SQLite closes. Open only the access URI with
  `mode=ro&immutable=1`, explicit read-only/URI flags, and verified `query_only`.
- Run `mise exec -- zig build fmt-check` and `mise exec -- zig build test`
  before handing off changes. Run `mise exec -- zig build interop` for encoder
  compactor, or wire-format changes when Go is available; normal tests stay
  network-free.
- For `ltx_sqlite` store or lifecycle changes, also run `mise exec -- zig build
  sqlite-integration -Doptimize=ReleaseSafe`. This host-only test may link the
  system SQLite and libc; neither library module may do so.
- For decoder or compression changes, also run the bounded native fuzz suite:
  `mise exec -- zig build fuzz --fuzz=10K -Doptimize=ReleaseSafe --seed 0`.
- Keep Linux and macOS CI on the exact Zig pin and pin workflow actions by full
  commit SHA. Go module downloads must remain checksum-locked.
- Project-original code is MIT-licensed. Preserve `LICENSE` and the separate
  required `LICENSE.pierrec-lz4` notice.
