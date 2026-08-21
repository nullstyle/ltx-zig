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
- Keep state transitions centralized and poison a decoder or encoder after a
  processing failure. Use `finish()`, not an ambiguous `close()`.
- Keep functions near or below 70 lines, use `snake_case`, capitalize acronyms
  such as `TXID`, and suffix quantities with units such as `_bytes` or `_count`.
- Canonical encoding zeros reserved bytes, uses flagged raw LZ4 blocks, emits
  pages and index entries in strict order, and is deterministic.
- Test positive and negative boundaries. Maintain independent Go-derived known
  answers; a Zig round trip alone is not an interoperability test.
- Do not describe planned support as implemented. In particular, legacy
  unflagged v3 LZ4 frames, v2, apply, and compaction are not currently supported.
- Run `mise exec -- zig build fmt-check` and `mise exec -- zig build test`
  before handing off changes. Run `mise exec -- zig build interop` for encoder
  or wire-format changes when Go is available; normal tests stay network-free.
- Keep Linux and macOS CI on the exact Zig pin and pin workflow actions by full
  commit SHA. Go module downloads must remain checksum-locked.
- This repository has no license. Leave license selection as an explicit TODO.
