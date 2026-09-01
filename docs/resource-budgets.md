# Resource budgets

`ltx` keeps codec processing allocation-free after initialization. Callers
provide fixed-capacity workspaces and must separately budget state values,
input/output storage, and any staged-apply backend storage. The public
`ltx_resources` module is the single checked source of truth for these formulas;
its implementation lives in [`src/resources.zig`](../src/resources.zig), and
the benchmark harness consumes the same module as applications.

Let:

- `P = Limits.max_page_size`
- `C = Limits.max_compressed_page_size`
- `I = Limits.max_page_index_entries`
- `E = @sizeOf(ltx.PageIndexEntry)` for the selected target
- `W = @sizeOf(ltx.LZ4CompressionWorkspace)` for the selected target
- `K` be the compaction input count
- `R = ltx_replication.Config.read_workspace_bytes`
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

The formulas assume separate, correctly aligned typed buffers. `ArenaCursor`
carves byte and typed-slice workspaces from one caller-owned arena with checked
alignment padding, multiplication, addition, and capacity. Successful bindings
advance monotonically and therefore cannot overlap. A zero-count binding is
valid and consumes no storage; nonempty bindings of zero-sized types and
invalid alignments are rejected. A plain sum is not an arena-layout formula.

Each compaction input owns a complete decoder workspace because every input is
independently bounded by `Limits`. The output encoder owns its own workspace.
`CompactionLimits.max_inputs` bounds `K`, while
`CompactionLimits.max_total_pages` separately bounds all decoded page events,
including pages later overwritten or dropped. `K` must be at least one.

## WAL page-map workspace

The `ltx_wal` module adds one scan operation with its own workspace. Let
`A = ltx_wal.Limits.max_pages`; the committed-page-map scan requires:

```text
wal page-map bytes = A * @sizeOf(ltx_wal.PageSlot)
  + A * @sizeOf(u32)
  + ceil(A / 8)
  + A * @sizeOf(ltx_wal.PageMapEntry)
```

covering the per-page committed/pending slots, the in-transaction page list,
its dedupe bitmap, and the ascending result entries. The `Reader` value and
the whole WAL input slice are separate resources: `ltx_wal` borrows frame
pages directly from the caller's slice and performs no allocation.
`max_frames` bounds every scan loop and must cover the whole input including
any torn tail. `ltx_resources.wal_page_map_workspace_bytes` checks this
formula.

## Replication-layer workspaces

`ltx_replica` executors use one decoder workspace per restore or compaction
input plus one encoder workspace for compaction output, exactly as the codec
table prescribes. Encoded inputs are consumed through bounded sequential
object-read windows instead of whole-object buffers:

```text
restore read bytes = R
K-input compaction read bytes = K * R
pooled restore + compaction read bytes = (K + 1) * R
```

`ltx_resources.replication_read_workspace_bytes` checks the pooled formula.

`R` must be nonzero and no larger than `Limits.max_input_bytes`. The object
size remains independently bounded by `Limits.max_input_bytes`; the replica
executors reject an oversized listed object before opening any source. A
complete sequential read performs at most
`ceil(object bytes / R)` backend range operations.
The controller validates every restore and compaction read slice against the
configured `R` and validates all read, codec, control, and output ranges for
aliasing.

`ltx_capture` uses the WAL page-map
workspace above, the encoder workspace for the emitted L0, one
`Limits.max_page_size` page buffer for database-file reads, and plain WAL
storage bounded by the accepted WAL size. With a transactional object adapter,
capture and compaction encode directly into private backend staging and their
output-storage slices may be empty. An adapter that only implements
whole-object `write` still requires a fallback region bounded by
`Limits.max_output_bytes`. S3's caller-owned send workspace is transport
staging (at most one multipart part), not codec output storage.

### Complete controller arena

`ltx_replication.Resources.arena_capacity_bytes(config, client)` is the
checked source of truth for one complete controller arena. Its result includes
the aligned `Resources` descriptor, capture storage, level and plan arrays,
restore storage, every configured compaction-input reader and decoder
workspace, and compaction encoder storage. The calculation includes
worst-case alignment padding so a byte slice of the returned length is
sufficient regardless of its starting address.

`Resources.bind(config, client, arena)` repeats the same checked planning and
then uses `ArenaCursor` to bind every byte and typed range monotonically. It
returns the `*Resources` descriptor stored inside the arena. Invalid
configuration, arithmetic overflow, or insufficient arena capacity fails
before a controller opens SQLite; no growing collection or allocator is
retained.

The object client's write-session capability is part of the capacity. A
transactional client receives empty capture and compaction whole-object output
slices because publication streams into private adapter staging. A client
without write sessions receives separate `Limits.max_output_bytes` fallback
regions for those operations. Capacity must therefore be calculated and bound
with the same client capability that will be passed to `Controller.init`.

The arena and returned descriptor must remain address-stable and exclusively
available to the controller until `Controller.finish()`; the caller must not
mutate or reuse their storage while the controller is live. Manual `Resources`
construction remains valid for hosts that use separate fixed buffers or an
existing storage layout; the controller applies the same capacity and
live-alias validation to both paths.

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
