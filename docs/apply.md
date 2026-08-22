# Staged apply

`StagedApplier` is the storage-neutral boundary between hostile LTX input and
an authoritative database image. It owns a decoder, uses caller-owned fixed
workspace, performs no allocation, and imports neither filesystem nor SQLite
APIs. A caller supplies an `ApplyBackend` whose callbacks manage one private
database image.

The core layer deliberately does not import SQLite or coordinate its connection
handles. The optional `ltx_sqlite` adapter implements this backend with a
host-owned quiescence gate and atomic filesystem generations; see
[`sqlite-store.md`](sqlite-store.md). It does not replace a fixed pathname while
SQLite has it open.

The public entry point combines decoder and apply initialization so the
session owns one coherent state machine:

```zig
var applier = try ltx.StagedApplier.init(
    .v3,
    codec_limits,
    .{
        .max_database_pages = 4096,
        .max_database_bytes = 16 * 1024 * 1024,
    },
    .contiguous,
    source.reader(),
    backend,
    &page_workspace,
    &compressed_workspace,
    &index_workspace,
);
const verified = try applier.apply();
```

## Lifecycle

An apply session is one shot:

```text
initialized -> staging -> published
     |            |  \
     +----------> failed
                  |
                  +-----> recovery_required
```

`StagedApplier` is a stateful, single-owner value. Copying it would duplicate
state while retaining the same transport, workspaces, and backend transaction,
so callers must operate only through the initialized instance.

`apply()` first asks the decoder for a validated header. It checks the final
database page and byte counts against `ApplyLimits` before calling the backend.
Only then does `begin` create private staging and return the authoritative
position and page-size metadata observed at that boundary.

The remaining sequence is:

1. check the requested transition mode against the position returned by
   `begin`;
2. decode each `UnverifiedPage` and copy it into private staging;
3. require the page index, trailer, logical file checksum, applicable snapshot
   checksum, and exact EOF to produce `VerifiedLTX`;
4. for checksummed LTX files, read every checksummed page from the completed
   private image and compare its rolling database checksum with the verified
   trailer;
5. call `publish` once.

No page callback authorizes publication. If an ordinary operation after a
successful `begin` fails, `StagedApplier` calls the infallible `abort` callback
exactly once and enters `failed`. A failed `begin` promises that it left no
active stage, so it is not followed by `abort`.

`ApplyPublishIndeterminate` is the sole exception. It means `publish` may have
crossed its durable commit point, so authoritative state may be either the old
or new image and position. Before returning this error, the backend ends its
private stage. `StagedApplier` therefore does not call `abort`; it enters
`recovery_required`, and the caller must use backend-specific recovery before
starting another apply. Calls after `published`, `failed`, or
`recovery_required` return `error.InvalidState` without invoking the backend
again.

No-checksum LTX files still require complete structural and file-checksum
verification. Their explicit wire contract omits the final database-image
checksum scan.

## Transition modes

Every session selects an `ApplyMode` explicitly:

- `.contiguous` requires the backend's current TXID to equal `MinTXID - 1`.
  When database checksums are enabled, the current checksum must also equal
  `PreApplyChecksum`. Every incremental also requires exact page-size
  compatibility, even when database checksums are disabled.
- `.replace_snapshot` bypasses that pre-position check only for a snapshot.
  Incremental files remain strictly contiguous in this mode.

A matching TXID with a mismatched enabled checksum is divergent history, not a
replacement request. Replacement is therefore visible at the call site and
cannot happen as a hidden recovery policy.

## Backend contract

`ApplyPlan` carries the selected format version and mode, the validated header,
and the overflow-checked final database byte size. The backend retains any plan
state needed by its later callbacks.

`ApplyBackend` contains a context pointer and five synchronous, non-reentrant
callbacks:

| Callback | Contract |
| --- | --- |
| `begin(plan)` | Open an isolated stage for exactly `plan.final_database_size_bytes`, then return the authoritative position and page-size metadata used to construct it. An error leaves no active stage. |
| `stage_page(page)` | Copy `page.data` before returning; decoder workspace is reused by the next operation. Apply it at the supplied checked page number and byte offset. |
| `read_page(number, destination)` | Fill the complete destination from the private staged image. This is used only for the pre-publication database checksum scan. |
| `publish(expected_current, verified)` | Atomically recheck the authoritative position and page-size metadata, install the complete staged image and its page size, and advance the position to `verified.post_apply_position()`. Ordinary errors publish none of those changes and leave staging active for `abort`. `ApplyPublishIndeterminate` may represent either the pre- or post-commit state and ends staging without `abort`. |
| `abort()` | Infallibly discard the active stage without changing authoritative bytes or position. |

For an incremental transition, `begin` constructs staging from the exact
authoritative image associated with the returned position, resizes it to the
planned final length, and then accepts page replacements. `StagedApplier`
compares the returned page-size metadata with the validated header before any
page is staged; this remains required when LTX database checksums are disabled.
The backend must separately reject an incompatible database layout that is not
represented by that metadata. `ApplyCurrent.page_size == null` means no page
size has ever been established and is rejected for an incremental; an empty
database produced by an earlier deletion must retain its established page-size
metadata. For a snapshot, `begin` constructs a zero-filled image of the planned
final length. The zero fill includes SQLite's omitted pending-byte lock page;
snapshot LTX files never carry a page frame for that page.

Publication is a storage transaction, not merely a final callback in program
order. The current-metadata comparison, complete-image installation or
replacement, page-size update, and position advance must share one atomic
commit or exclusive lock. If another writer changes the state after `begin`,
`publish` returns `NonContiguousTransition`, `DivergentHistory`, or
`DatabasePageSizeMismatch` and leaves the authoritative state untouched.
An adapter that cannot determine whether its durable commit completed instead
returns `ApplyPublishIndeterminate`; it must expose a recovery operation that
resolves the authoritative image and position before accepting more work.

`ApplyBackend.backing_bytes`, when available, lets initialization reject
aliasing between backend staging, input, and codec workspaces. All unreported
backend storage and callback context must likewise remain live, address-stable,
exclusive, and non-overlapping until the session reaches a terminal state.
`StagedApplier` is a single-owner value and must not be copied: copies would
share decoder storage and backend transaction context while duplicating state.

## Bounds and storage adapters

`ApplyLimits.max_database_pages` and `max_database_bytes` independently bound
the completed image before staging begins. Codec limits continue to bound
input, page count, page size, compressed data, index storage, and every decode
loop. The full-image checksum pass uses the existing page workspace one page at
a time; it does not allocate an image, page list, or checksum table. It cannot
observe bytes beyond the planned final length, so exact staging length remains
part of the backend's `begin` and atomic publication contract.

The optional SQLite store implements this boundary with one inactive database
slot and a checksummed manifest as the sole commit pointer. A canonical empty
manifest is durably installed before the first slot is created, giving first
publication the same atomic old/new selection as later generations.
`stage_page` never writes into the manifest-selected generation. Its lifecycle
hook drains host SQLite connections, it rejects rollback-journal, WAL, and SHM
sidecars, and typed generation accesses hold a shared advisory lock from
manifest resolution through SQLite close. Publication and recovery take that
lock exclusively. The publication sequence syncs the staged database, temporary
manifest, and parent directory around the atomic rename. These policies remain
outside the core and are documented in [`sqlite-store.md`](sqlite-store.md).
