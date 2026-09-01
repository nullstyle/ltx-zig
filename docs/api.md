# Current API and stability

`ltx-zig` is pre-1.0. Its Zig source API is intentionally unstable and may
change in any 0.x release. Development is coordinated with one consumer;
other users should pin an exact tag or commit and expect to update their code.
No source-compatibility, layout, or ABI guarantee is made before 1.0.

This policy applies to declaration names, public fields, enum and error tags,
function signatures, and the optional SQLite-store adapter. Intentional source
changes update the coordinated consumer, examples, and documentation in the
same change; they do not require a compatibility shim or deprecation period.

Wire-format behavior is governed separately. LTX v2 import and LTX v3 behavior
remain anchored to separately pinned `superfly/ltx` revisions, checked-in
fixtures, and the interoperability matrix. Celld remains a secondary v3
deployment reference and supplies no v2 oracle. A source API change does not
relax those byte-level compatibility or safety requirements.

## Current modules

- `ltx` provides the libc-free decoder, encoder, compactor, staged applier,
  checksum helpers, bounded transports, and their caller-owned workspaces.
  Decoders and staged appliers require explicit `.v2` or `.v3` selection because
  both formats use `LTX1`. The encoder accepts only `.v3`. Compaction can select
  a version per input and always emits canonical v3.
- `ltx_sqlite` provides the optional host-filesystem generation store. It uses
  `ltx` and can publish a verified image decoded from v2 or v3 without linking
  SQLite or libc.
- `ltx_wal` parses bounded caller-owned SQLite WAL bytes into committed page
  maps, validates salts and cumulative checksums, tolerates a torn tail, and
  supports seeded mid-WAL resume without linking SQLite.
- `ltx_object` defines the synchronous storage-neutral object contract and its
  filesystem adapter in the Litestream layout, including the reusable backend
  conformance suite. Exact positional reads fill caller-owned slices, and the
  allocation-free `ObjectReader` adapts them to a bounded sequential codec
  reader. Optional transactional write sessions expose a bounded `ltx.Writer`;
  `finish` is their only publication attempt and `abort` discards private
  staging. `PublicationIndeterminate` means the adapter crossed its commit
  point but could not confirm durable publication, so the caller must reconcile
  the object identity.
- `ltx_s3` implements that object contract over the standard-library HTTP
  client with path-style or virtual-host SigV4, TLS, bounded retry, paginated
  listings, conditional writes, and automatic single-or-multipart
  transactional upload. Its pooled HTTP connections use the allocator supplied
  at initialization. Fenced and transactional publication report remote
  post-send uncertainty as `PublicationIndeterminate`; reconcile the exact
  object identity before durable progress advances.
- `ltx_replica` provides the Litestream level ladder, restore, compaction, and
  retention planners, plus restore and compaction executors over caller-owned
  workspaces. They remain public lower-level escape hatches beneath the
  controller.
- `ltx_capture` provides the WAL-mode SQLite capture session, no-checksum L0
  publication, seeded continuation after restore, mid-WAL resume, snapshot
  fallback on foreign WAL discontinuity, and byte-, age-, and frame-bounded
  passive checkpoint policy. `checkpoint_pending` exposes an automatic
  checkpoint retry that could not complete after a successful capture. It
  alone declares a SQLite C surface; the host executable links the system
  SQLite library.
- `ltx_resources` is the public checked source of truth for codec, apply, WAL,
  and wire capacities. `ArenaCursor` binds typed and byte workspaces out of one
  fixed caller-owned arena without overlap or allocation.
- `ltx_replication` provides the synchronous per-database `Controller`. It
  owns capture position, all-level listing, startup restore, one selected
  adjacent-level maintenance quantum, safe retention, and restore execution;
  the host retains scheduling, concurrency, acknowledgement, and fencing.
  Restore-latest startup requires a host-quiesced target with no SQLite
  sidecars, and initialization copies the level ladder and validates every
  simultaneously live resource range. `Resources.arena_capacity_bytes`
  derives the checked capacity for a configuration and object client, and
  `Resources.bind` places the descriptor and every controller workspace in one
  caller-owned fixed arena. Callers with separately provisioned storage may
  continue constructing `Resources` manually. `Controller.diagnostics()`
  returns a fixed-size, pointer-free copy of lifecycle, per-operation
  saturating counters, and the exact last accepted result or failure. It is an
  observation for the controller's single owner between synchronous calls,
  including after poison or finish; it is not a synchronization primitive.

The core remains synchronous and allocation-free after initialization. Page
events are unverified; publication and trusted post-apply positions are valid
only after terminal verification. Apply still uses private staging and one
atomic publication boundary. See [design.md](design.md),
[compaction.md](compaction.md), and [apply.md](apply.md) for those invariants.

`FormatVersion` is not auto-detection. A caller must obtain the version from
trusted object metadata, a replica generation contract, or other out-of-band
configuration before constructing a decoder. The selected layout is
authoritative; malformed input under it fails boundedly, and the library never
guesses from the shared magic or retries hostile bytes under another layout.

The SQLite adapter requires a host-owned quiescence gate and held generation
access until SQLite closes. Open only its immutable read-only URI with the
provided flags and verified `query_only` statement. `FaultPoint` and
`FaultInjection` are test facilities and may change without notice. See
[sqlite-store.md](sqlite-store.md) for the lifecycle contract.

## Current-consumer qualification

The external path-dependency fixture verifies that the package exposes all
nine current public modules through normal Zig dependency wiring:

```sh
mise exec -- zig build consumer-compile
mise exec -- zig build consumer-smoke
```

This fixture is a regression check for the current coordinated consumer, not a
source-compatibility guarantee. It may be updated alongside intentional 0.x
source changes.
`source-archive-smoke` additionally creates Zig's canonical local `zig fetch`
tarball, extracts it with isolated caches, and runs the archived consumer plus
all four shipped examples, including the SQLite-linked replication lifecycle.
That gate checks package completeness without promising future source
compatibility.
