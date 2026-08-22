# Public 0.1 API contract

The supported `ltx-zig` 0.1 API is a source-level contract for Zig 0.16.0.
Consumers obtain the package as `ltx_zig` and may import either public module:

- `ltx` provides the libc-free codec, compactor, and staged-apply API.
- `ltx_sqlite` provides the optional host-filesystem generation store. It uses
  `ltx`, but neither public module links SQLite or libc.

The executable contract is
[`tests/consumer/src/api_0_1.zig`](../tests/consumer/src/api_0_1.zig). It imports
the package exactly as an external consumer, constructs supported public data,
references required enum and error tags, and binds public constructors,
methods, and callbacks to explicit function types.

## Compatibility boundary

The contract protects supported declaration names, public fields used to
construct values, constants and wire values, required enum and error tags, and
function and callback signatures. Removing or renaming one of these, changing
its type incompatibly, or changing a pinned wire value requires an intentional
compatibility decision. Adding unrelated declarations is allowed; the contract
does not require the public modules to contain only the names listed here.

This is not a binary ABI or memory-layout promise. Consumers must not depend on
`@sizeOf`, `@alignOf`, field offsets, padding, or an in-memory byte
representation for these types. In particular, LTX bytes must be processed
through the encoder and decoder rather than by overlaying a Zig struct on wire
data.

## `ltx`

| Area | Supported source surface |
| --- | --- |
| Domain and wire values | `Error`, `FormatVersion` with `.v3`, `TXID`, `Checksum`, `Position`, `Header`, `PageHeader`, `PageIndexEntry`, `Trailer`, `UnverifiedPage`, `VerifiedLTX`, and `Limits` |
| Constants and checksums | `checksum_flag`, `header_flag_no_checksum`, `page_header_flag_size`, `header_size`, `page_header_size`, `trailer_size`, `sqlite_pending_byte`, `lock_page_number`, `checksum_page`, `rolling_checksum_initial`, and `rolling_checksum_add` |
| Transports | `Reader` and `Writer`, including their callback fields and methods, plus `SliceReader` and `SliceWriter` and their constructors/adapters |
| Decoding | `Decoder`, `DecoderState`, and `DecoderEvent`; `Decoder.init`, `next`, `current_state`, `selected_format_version`, and `event_budget` |
| Encoding | `Encoder`, `EncoderState`, and `LZ4CompressionWorkspace`; `Encoder.init`, `write_header`, `write_page`, `finish`, `current_state`, and `selected_format_version` |
| Compaction | `CompactionLimits`, `CompactionInput`, `CompactorState`, and `Compactor`; their validation/initialization operations plus `compact`, `current_state`, and `selected_format_version` |
| Staged apply | `ApplyLimits`, `ApplyMode`, `ApplyState`, `ApplyPlan`, `ApplyCurrent`, `StagedPage`, `ApplyBackend`, and `StagedApplier`; the five backend callbacks and `StagedApplier.init`, `apply`, and `current_state` |

The state, event, mode, and error tags referenced by the executable consumer
contract are included in this source surface. A page event remains unverified;
only a successful terminal `VerifiedLTX` authorizes publication or a trusted
post-apply position.

## `ltx_sqlite`

| Area | Supported source surface |
| --- | --- |
| Names and capacities | `manifest_name`, `manifest_temporary_name`, `lock_name`, `database_a_name`, `database_b_name`, `max_generation_path_bytes`, and `max_generation_uri_bytes` |
| Status and configuration | `Error`, `Failure`, `StoreState`, `Slot`, `Lifecycle`, and production `Options` |
| Current generation | `Current`, `GenerationAccessWorkspace`, `GenerationAccessStorage`, `GenerationAccess`, and `SQLiteOpenSpec` |
| Store operations | `Store.init`, `backend`, `current_state`, `last_failure`, `current`, `acquire_generation`, and `recover` |
| Held-access operations | `GenerationAccess.current`, `sqlite_open_spec`, and `release`, plus `Slot.database_name` and `Current.database_name` |

`Lifecycle` callback signatures are part of the contract. A successful
`quiesce_fn` must stop new opens and drain owned SQLite connections until its
matching `release_fn`. A held `GenerationAccess` protects the selected file
until every SQLite resource using it has closed and `release` succeeds.
`SQLiteOpenSpec` supplies the immutable read-only URI, required open flags, and
`query_only` statement; the host still owns the SQLite connection.

`FaultPoint` and `FaultInjection` are explicitly outside this contract. They
remain public only for deterministic in-tree durability and crash tests, are
unstable during the 0.x series, and carry no source-compatibility guarantee.
Production callers must leave fault injection disabled; `Options{}` is the
canonical production configuration.

## Qualification

Run the external source contract without executing it, then run the consumer:

```sh
mise exec -- zig build api-freeze
mise exec -- zig build consumer-smoke
```

ReleaseSafe qualification uses the same commands with
`-Doptimize=ReleaseSafe`. `source-archive-smoke` additionally creates Zig's
canonical local `zig fetch` tarball, extracts it into an isolated temporary
tree, uses isolated local and global caches, and runs the archived external
consumer plus every shipped example. This proves that package `.paths` contain
the files needed by those supported entry points without falling back to the
live checkout or an existing cache.
