# Resource budgets

`ltx` keeps codec processing allocation-free after initialization. Callers
provide fixed-capacity workspaces and must separately budget state values,
input/output storage, and any staged-apply backend storage. The checked formulas
used by the benchmark harness live in
[`benchmarks/resource_model.zig`](../benchmarks/resource_model.zig).

Let:

- `P = Limits.max_page_size`
- `C = Limits.max_compressed_page_size`
- `I = Limits.max_page_index_entries`
- `E = @sizeOf(ltx.PageIndexEntry)` for the selected target
- `W = @sizeOf(ltx.LZ4CompressionWorkspace)` for the selected target
- `K` be the compaction input count
- `N` be the number of encoded pages
- `V = Limits.max_varint_bytes`

Every conversion and addition or multiplication in a capacity calculation must
be checked. `usize` is used only where a caller will construct a slice; logical
database and wire quantities remain fixed-width until that boundary.

## Codec workspaces

The exact caller-owned variable workspace totals are:

| Operation | Workspace bytes |
| --- | ---: |
| Decoder | `P + C + I * E` |
| Encoder | `C + W + I * E` |
| `K`-input compactor | `K * (P + C + I * E) + C + W + I * E` |
| Staged apply | `P + C + I * E` |

These totals exclude `Decoder`, `Encoder`, `CompactionInput`, `Compactor`, and
`StagedApplier` values; reader/writer and backend state; encoded inputs; source
database pages; and encoded output. Their `@sizeOf` and `@alignOf` values depend
on the compilation target. No source-compatibility, ABI, or numeric-layout
guarantee is made for them before 1.0.

The formulas assume separate, correctly aligned typed buffers. When carving
them from one byte arena, apply checked alignment padding before
`PageIndexEntry`, `LZ4CompressionWorkspace`, and state/control values. A plain
sum is not an arena-layout formula.

Each compaction input owns a complete decoder workspace because every input is
independently bounded by `Limits`. The output encoder owns its own workspace.
`CompactionLimits.max_inputs` bounds `K`, while
`CompactionLimits.max_total_pages` separately bounds all decoded page events,
including pages later overwritten or dropped. `K` must be at least one.

## Compression capacity

For a valid SQLite page size `P`, the current fast LZ4 encoder's checked output
capacity is:

```text
fast LZ4 bytes = P + floor(P / 255) + 16
```

The minimum capacity accepted by `Encoder.init` is the canonical literal-block
fallback bound:

```text
literal fallback bytes = P + 2 + floor((P - 15) / 255)
```

The encoder and compactor workspace helpers reject a configured compressed-page
capacity below that bound, matching `Encoder.init`. Decoder and staged-apply
workspace helpers accept any otherwise valid decoder capacity. `P` is a limit
ceiling and need not itself be a SQLite page size; the standalone bound helpers
require an actual valid SQLite page size.

The literal bound never exceeds the fast bound for a valid SQLite page size.
Setting `Limits.max_compressed_page_size` to at least the literal bound permits
canonical encoding; setting it to at least the fast bound also provides enough
capacity to run the fast compressor instead of forcing literal fallback.

## Database and apply storage

The final logical database length is the checked product:

```text
database bytes = commit pages * page size bytes
```

It must fit both `ApplyLimits.max_database_pages` and
`ApplyLimits.max_database_bytes`. This length is not part of the staged
applier's codec-workspace total. A file backend can stage it without holding a
second full image in RAM. A simple atomic memory backend may retain the current
published image while building the final staged image, so its peak image
storage budget is:

```text
current published database bytes + final staged database bytes
```

That sum can exceed twice the final length when a commit shrinks the database.
It is a backend policy, not a `StagedApplier` requirement.

A checksummed apply reads every committed database page except SQLite's
pending-byte lock page when that page lies at or below the commit. A
no-checksum apply performs no database read-back scan. Both modes still stage
the LTX page events and perform complete structural and file-checksum
verification.

## Current flagged-wire upper bounds

A flagged page frame contains a six-byte page header, a four-byte compressed
size prefix, and at most `C` compressed bytes. The file also contains its
100-byte header, a six-byte page sentinel, page index, and 16-byte trailer.
For `N` pages, the configured structural bound is:

```text
122 + N * (10 + C) + Limits.max_page_index_bytes
```

The coarse varint-derived index bound is three `V`-byte values per page, a
one-byte zero terminator, and an eight-byte index-size field. Substitution gives:

```text
131 + N * (10 + C + 3 * V)
```

`N` must not exceed either `Limits.max_pages` or
`Limits.max_page_index_entries`. `Limits.max_output_bytes` is an independent
transport limit: the encoder rejects an output that crosses it, while a slice
writer still requires the caller to provide whatever fixed capacity the chosen
workload needs. Taking the smaller of the configured-index and coarse-varint
bounds is a valid tighter structural capacity when both calculations succeed.

The bounds describe canonical encoder output: the current flagged LZ4 v3
representation. They are not a wire-size promise for decoder-only v2 input,
legacy unflagged v3 input, or a future format version.

## Informational example

For a configuration with 4,096-byte pages, 4,128 compressed bytes, 256 page
index entries, 256 pages, and ten-byte maximum varints, the formulas remain:

```text
decoder workspace = 4096 + 4128 + 256 * @sizeOf(ltx.PageIndexEntry)
encoder workspace = 4128 + @sizeOf(ltx.LZ4CompressionWorkspace)
                    + 256 * @sizeOf(ltx.PageIndexEntry)
four-input compactor workspace = 4 * decoder workspace + encoder workspace
database bytes = 256 * 4096
coarse flagged-wire bytes = 131 + 256 * (10 + 4128 + 3 * 10)
```

The `@sizeOf` terms must be evaluated for the actual target. No numeric struct
size, alignment, padding, or aggregate total in this example is an ABI promise,
and tests intentionally keep those terms symbolic.
