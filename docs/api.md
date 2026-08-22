# Current API and stability

`ltx-zig` is pre-1.0. Its Zig source API is intentionally unstable and may
change in any 0.x release. Development is coordinated with one consumer;
other users should pin an exact tag or commit and expect to update their code.
No source-compatibility, layout, or ABI guarantee is made before 1.0.

This policy applies to declaration names, public fields, enum and error tags,
function signatures, and the optional SQLite-store adapter. Intentional source
changes update the coordinated consumer, examples, and documentation in the
same change; they do not require a compatibility shim or deprecation period.

Wire-format behavior is governed separately. Supported LTX v3 bytes remain
qualified against the pinned `superfly/ltx` oracle, the Celld deployment
reference, checked-in fixtures, and the interoperability matrix. A source API
change does not relax those byte-level compatibility or safety requirements.

## Current modules

- `ltx` provides the libc-free decoder, encoder, compactor, staged applier,
  checksum helpers, bounded transports, and their caller-owned workspaces.
- `ltx_sqlite` provides the optional host-filesystem generation store. It uses
  `ltx`, but neither public module links SQLite or libc.

The core remains synchronous and allocation-free after initialization. Page
events are unverified; publication and trusted post-apply positions are valid
only after terminal verification. Apply still uses private staging and one
atomic publication boundary. See [design.md](design.md),
[compaction.md](compaction.md), and [apply.md](apply.md) for those invariants.

The SQLite adapter requires a host-owned quiescence gate and held generation
access until SQLite closes. Open only its immutable read-only URI with the
provided flags and verified `query_only` statement. `FaultPoint` and
`FaultInjection` are test facilities and may change without notice. See
[sqlite-store.md](sqlite-store.md) for the lifecycle contract.

## Current-consumer qualification

The external path-dependency fixture verifies that the package exposes working
`ltx` and `ltx_sqlite` modules through normal Zig dependency wiring:

```sh
mise exec -- zig build consumer-compile
mise exec -- zig build consumer-smoke
```

This fixture is a regression check for the current coordinated consumer, not a
source-compatibility guarantee. It may be updated alongside intentional 0.x
source changes.
`source-archive-smoke` additionally creates Zig's canonical local `zig fetch`
tarball, extracts it with isolated caches, and runs the archived consumer plus
all shipped examples. That gate checks package completeness without promising
future source compatibility.
