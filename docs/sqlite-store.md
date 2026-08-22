# Quiescent SQLite generation store

The optional SQLite store adapter publishes exact, verified LTX database bytes
without mutating a database that SQLite has open. It is a filesystem adapter to
`ApplyBackend`, not a SQLite binding: the host application remains responsible
for its SQLite library, connection pool, statements, BLOB handles, checkpoints,
and admission control.

## Why publication uses generations

Replacing a conventional `main.sqlite` pathname while SQLite still has the old
inode open is unsafe. SQLite derives rollback-journal, WAL, and shared-memory
names from that pathname, so old and new main files can become paired with the
wrong auxiliary state. Keeping LTX position metadata in a second sidecar does
not solve the problem: two independent renames cannot atomically publish one
database image and one position.

The store instead retains two closed database slots and makes one fixed-size,
checksummed manifest the sole authority. Each manifest record binds all of the
following values together:

- active database slot;
- monotonically increasing store generation;
- LTX TXID and post-apply checksum;
- SQLite page size;
- exact database length.

Published generations are immutable. Applications may open the selected
generation only through read-only SQLite connections (prefer both URI
`mode=ro` and `PRAGMA query_only=ON`). A writer would change bytes without
atomically advancing the manifest's LTX position; this adapter is therefore an
apply/replica destination, not the local-writer capture path.

An apply clones or zero-initializes the inactive slot, writes LTX pages only to
that private file, verifies the completed image, syncs it, and prepares a new
manifest. Renaming the prepared manifest is the single namespace commit point.
The previously active slot is retained, so either manifest outcome after a
crash still references a complete image.

## Required connection protocol

Every SQLite connection must be owned by a cooperating application lifecycle.
Before `begin` returns, its quiesce callback must:

1. stop admission of new connections and transactions;
2. finalize every statement, BLOB, and backup handle;
3. checkpoint and truncate WAL state through the application's SQLite library;
4. disable persistent WAL behavior where it is enabled;
5. close every connection and require `sqlite3_close()` to return `SQLITE_OK`;
6. keep admission closed until the store invokes the infallible release
   callback; an indeterminate publication retains that gate through recovery.

The store then requires the active and staging slot names to have no `-wal`,
`-shm`, or `-journal` sibling. It does not delete those files: their presence
means SQLite recovery or connection draining is incomplete, so apply fails
closed. The application must clear them through the same SQLite library and VFS
that owns the database.

The permanent advisory lock serializes cooperating store processes. It does
not coordinate an arbitrary process that opens a generation path directly.
Applications must resolve the manifest-selected slot while holding their own
admission/shared-lease protocol and must never expose a mutable symlink or
fixed-path alias as the database identity.

## Publication and failures

Publication is ordered as follows:

```text
quiesce connections
  -> lock store
  -> build inactive database
  -> verify exact staged image
  -> sync inactive database
  -> sync directory
  -> write and sync temporary manifest
  -> rename temporary manifest over current manifest   (commit point)
  -> sync directory
  -> unlock and release admission gate
```

Failures before the manifest rename leave the old manifest authoritative.
`StagedApplier` calls `abort`, which closes the private file and releases the
gate without deleting the authoritative slot. A fresh store may remove its
first uncommitted slot as bounded cleanup.

There is one unavoidable uncertain outcome: the manifest rename can succeed
and the following directory sync can fail. The new manifest may be visible but
its power-loss durability is not known. The adapter reports
`error.ApplyPublishIndeterminate`; the applier enters `recovery_required` and
does not call `abort`. The adapter closes staging and releases the filesystem
lock but deliberately retains the application admission gate. Recovery reuses
that held gate, retries the directory sync, and releases admission only after a
valid manifest-selected generation is durable. Image and position remain
paired even when the original publication caller could not know which
generation survived.

## Recovery rules

Recovery runs behind the same closed admission gate and exclusive store lock.
It validates the manifest checksum and reserved bytes, the selected slot, exact
database length, SQLite header and page size, and absence of SQLite auxiliary
files. For a checksummed position it also streams the full database through the
caller-owned bounded workspace and recomputes the rolling LTX checksum. It
never chooses a slot by timestamp and never treats a temporary manifest as
committed. A missing manifest is accepted only for a completely fresh directory
with no slot or temporary manifest; torn, unsupported, ambiguous, or internally
inconsistent state fails closed.

After recovery succeeds, the application may resolve and open the selected
generation. A later apply can safely reuse the inactive slot; abandoning a
pre-commit stage needs no unbounded orphan scan or allocation.

Once `recover()` has successfully quiesced the lifecycle, every later recovery
error—including corrupt state, I/O failure, or lock contention—leaves that gate
held and the store in `recovery_required`. Repair the cause and retry recovery
on the same `Store`, or terminate the process. Do not reopen SQLite after a
recovery error. This fail-closed rule also applies when recovery was invoked at
startup rather than after an indeterminate apply.

## Deployment boundary

The adapter targets local filesystems on macOS and Linux whose rename, advisory
lock, file-sync, and directory-sync behavior follows the host contracts. Network
filesystems, uncontrolled clients, `nolock=1`, unsafe SQLite journal modes, and
storage that lies about sync are outside the durability model. On Darwin,
`std.Io.File.sync` provides the ordinary `fsync` contract; deployments that
require stronger physical-media guarantees should supply that at the platform
layer.

Lifecycle implementations that operate a multi-connection WAL database should
use SQLite 3.51.3 or newer; SQLite's
[3.51.3 release](https://www.sqlite.org/releaselog/3_51_3.html) fixed a WAL-reset
race present in 3.51.0 through 3.51.2.

SQLite Online Backup is deliberately not used. Although it creates a valid
logical copy, SQLite changes page-one transaction metadata and the destination
schema cookie during backup. Those bytes participate in the LTX page checksum,
so the result is not the exact verified LTX image.
