# Compatibility matrix

The status terms are `supported`, `tested`, `planned`, and `unsupported`.
`Tested` means automated Zig coverage unless the evidence explicitly says the
check is manual; pinned upstream vectors are identified in the evidence.

| Capability | Status | Evidence or boundary |
| --- | --- | --- |
| Explicit format selection | Tested | `.v3` succeeds; v2 returns `UnsupportedFormatVersion` |
| Decode current Go output | Tested | Byte-exact snapshot, incremental, no-checksum, maximum-page, and near-lock fixtures |
| Decode Celld/Go v0.5.2 vector | Tested | Pinned byte-exact two-page, multi-index-entry fixture |
| Go decodes Zig output | Tested | Optional automated `zig build interop` uses the exact pinned Go module |
| Flagged raw LZ4 block frames | Tested | Zig reproduces complete pinned Go and Celld match-compressed files byte for byte |
| Normal compressed matches | Tested | Exact pierrec/Celld vectors cover overlap, extension lengths, workspace reset, and 512..65536-byte pages |
| Legacy unflagged v3 frames | Tested | Historical Go compressed and stored-block fixtures; canonical one-block 64 KiB profile |
| LTX v2 | Unsupported | Same magic is never auto-detected or reinterpreted |
| Snapshots | Tested | One-page and empty pinned Go fixtures; completeness enforced |
| Incremental transitions | Tested | Pinned Go two-page fixture plus strict order and checksum-continuity tests |
| No-checksum files | Tested | Pinned Go fixture; pre/post database checksums zero, file checksum required |
| Empty database transitions | Tested | Go fixture uses post checksum `0x8000000000000000` |
| Page-index validation | Tested | Exact entries, offsets, sizes, canonical varints, and byte size |
| Nonzero reserved header bytes | Supported | Accepted by structural header decoding; encoder emits zero |
| Trailing-byte rejection | Tested | Exact EOF required after the trailer |
| Truncation boundaries | Tested | Every strict prefix of one current and one legacy Go fixture is rejected |
| Position contiguity | Tested | Exact TXID and enabled-checksum equality |
| Compaction | Unsupported | Future layer above the verified codec |
| Direct SQLite apply | Unsupported | Future staging layer must publish only after verification |

The encoder uses a bounded port of the fast raw-block compressor pinned by Go
and independently ported by Celld. With the canonical output bound it preserves
their exact match choices and bytes. A deliberately smaller but still safe
configured cap selects deterministic literal-only blocks. The decoder accepts
both forms. Legacy decoding is strictly scoped to the independent 64 KiB,
content-checksummed frame profile emitted by upstream; other standard LZ4 frame
options return `UnsupportedPageEncoding`.
