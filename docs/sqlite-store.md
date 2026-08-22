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

Published generations are immutable. Applications must hold their generation
lease and open the selected path using SQLite's
[URI options](https://www.sqlite.org/uri.html) `mode=ro&immutable=1`, plus
`PRAGMA query_only=ON`. The immutable option is needed when exact LTX bytes
retain SQLite's WAL-mode header but the required quiescence protocol has removed
`-wal` and `-shm`. It also makes SQLite skip locking and external-change
detection, so it is safe only while the lifecycle guarantees that the selected
slot cannot be reused or changed until every such connection is closed. A
writer would change bytes without atomically advancing the manifest's LTX
position; this adapter is therefore an apply/replica destination, not the
local-writer capture path.

An apply clones or zero-initializes the inactive slot, writes LTX pages only to
that private file, verifies the completed image, syncs it, and prepares a new
manifest. Renaming the prepared manifest is the single namespace commit point.
The previously active slot is retained, so either manifest outcome after a
crash still references a complete image.

Before the first slot is created, the store publishes and syncs a canonical
empty `ltx.current` record. It selects no database and maps to the empty LTX
position. First publication therefore has the same old/new outcomes as every
later publication: before the commit point the empty record remains
authoritative, and after it the manifest selects generation one. A first-stage
crash cannot leave a missing manifest plus an ambiguous database image.

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
fixed-path alias as the database identity. URI filenames must be encoded rather
than built by appending unescaped path bytes.

## Publication and failures

Publication is ordered as follows:

```text
quiesce connections
  -> lock store
  -> initialize and sync empty manifest (first use only)
  -> sync the directory entry of any manifest observed from a prior process
  -> build inactive database
  -> verify exact staged image
  -> sync inactive database
  -> sync directory
  -> write and sync temporary manifest
  -> sync directory
  -> rename temporary manifest over current manifest   (commit point)
  -> sync directory
  -> unlock and release admission gate
```

Failures before the manifest rename leave the old manifest authoritative,
including the canonical empty record during first publication.
`StagedApplier` calls `abort`, which closes the private file and releases the
gate without deleting the authoritative slot. When the empty record is
authoritative, the first uncommitted slot is bounded garbage and may be removed.
Before reusing an inactive slot, a replacement process first syncs the directory
entry of the manifest it observed. This prevents a previously visible but
unsynced manifest rename from rolling back after its predecessor slot has been
replaced.

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
committed. On a pristine directory—or a temp-only interrupted empty
initialization—it creates the canonical empty manifest durably. A missing
manifest plus either database slot remains ambiguous and fails closed.

When the empty manifest is authoritative, recovery deletes both uncommitted
slots and the temporary manifest, then syncs the directory. `begin` performs
the same bounded cleanup before retrying a first snapshot, so an
application-process crash during first publication can be retried without
manual file removal. Non-snapshot LTX files remain invalid against the empty
position.

After recovery succeeds, the application may resolve and open the selected
generation. A later apply can safely reuse the inactive slot; abandoning a
pre-commit stage needs no unbounded orphan scan or allocation.

Once `recover()` has successfully quiesced the lifecycle, every later recovery
error—including corrupt state, I/O failure, or lock contention—leaves that gate
held and the store in `recovery_required`. Repair the cause and retry recovery
on the same `Store`, or terminate the process. Do not reopen SQLite after a
recovery error. This fail-closed rule also applies when recovery was invoked at
startup rather than after an indeterminate apply.

The test suite terminates a separate process immediately after every baseline
and publication durability boundary, then reopens and recovers the store through
a fresh `Store` in the parent process. These tests prove resource abandonment,
lock release, and deterministic visible old/new selection after an application
crash. They do not simulate a machine power loss; the sync/rename ordering and
filesystem contract are the basis for that guarantee.

## Deployment boundary

The adapter targets local filesystems on macOS and Linux whose rename, advisory
lock, file-sync, and directory-sync behavior follows the host contracts. Network
filesystems, uncontrolled clients, `nolock=1`, unsafe SQLite journal modes, and
storage that lies about sync are outside the durability model. On Darwin,
`std.Io.File.sync` provides the ordinary `fsync` contract; deployments that
require stronger physical-media guarantees should supply that at the platform
layer.

Lifecycle implementations that operate a multi-connection WAL database should
use SQLite 3.51.3 or newer, or a fixed 3.44.6/3.50.7 backport. SQLite's
[WAL documentation](https://www.sqlite.org/wal.html) says the WAL-reset race
likely affected releases from 3.7.0 through 3.51.2.

SQLite Online Backup is deliberately not used. Although it creates a valid
logical copy, SQLite changes page-one transaction metadata and the destination
schema cookie during backup. Those bytes participate in the LTX page checksum,
so the result is not the exact verified LTX image.
