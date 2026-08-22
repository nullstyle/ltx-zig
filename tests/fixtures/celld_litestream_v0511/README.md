# Celld/Litestream v0.5.11 capture

This directory is a verbatim L0 replica subtree from the immutable
`denoland/celld` golden corpus at commit
`89e4ffc53a14ecb496d2ca5014ff9d19b0061ad9`. Celld captured it with the real
Litestream v0.5.11 binary built from commit
`016c368704e63db0088b9b61e2e96c0019f11832` and SQLite 3.51.0. The upstream
[manifest](https://github.com/denoland/celld/blob/89e4ffc53a14ecb496d2ca5014ff9d19b0061ad9/crates/ltx/tests/fixtures/golden/MANIFEST.md)
marks the bytes immutable; its
[capture script](https://github.com/denoland/celld/blob/89e4ffc53a14ecb496d2ca5014ff9d19b0061ad9/crates/ltx/scripts/capture-golden.sh)
documents the SQL sequence and reproduction procedure.

The `.ltx` files are copied byte for byte. Their lowercase `.hex` mirrors
are repository-local review artifacts consumed by `zig build
materialize-fixtures`. Do not regenerate these files during normal tests.
Re-running the upstream capture produces equivalent content but not identical
bytes because the headers contain timestamps.

## Known answers

Every file is LTX v3 with 4096-byte pages, commit 5, no database checksums,
WAL offset 32, node ID zero, pages 1 through 5, and legacy unflagged LZ4
frames. TXID 1 is a snapshot; TXIDs 2 through 6 are contiguous single-TXID
incrementals. The test suite pins every remaining header field and trailer
file checksum.

| TXID | LTX bytes | LTX SHA-256 | Database SHA-256 after applying this prefix |
| ---: | ---: | --- | --- |
| 1 | 826 | `7c94a5482497ffe04fea81e595a714496526d886a0771e1747427509a3dcc7d4` | `75950c90007de1e7ee56e22ddf9d6d89d32eb12842f6deb0c9f623bfe086261b` |
| 2 | 858 | `b51b20e62a6bee6a73f699edcdc029a148eb5b4dcc1293f279fa4b2f8f6af87a` | `91c4e7cd5d2d5bc3ae85530719aabf3085fde037a9c0beb61b624dc8bc191f30` |
| 3 | 881 | `21d8ee050b708671d0ec81951b5233dc7377ef3714e073671c7a76179f9e64d8` | `f48d034fb60ca741f268b5ec52305f97c8cec1cbbbcc8064006094d0b81967af` |
| 4 | 901 | `e07ac074da97eba4f589ecb12f2b5ca4d2f75961b129b37383180acaae3dbf58` | `27d2e8ad59731445c4798eec1c76146e85bd931383728d89fbd96f91d97b0f6a` |
| 5 | 923 | `3a7df36075b697884c3bc7e20a42449bb8a7479e2ef6e8152e2f724a955a8a36` | `a7e0ac305a281beb14c07d8ecce95e7a81369dfaa9f2c67bd168c016c8408261` |
| 6 | 941 | `63ae1bd243decb488f8a704afd3c5cc726ff05efa70d4b53d960a49fe9f5a2bd` | `ee705e74c9788b64f5dc63b9c3dc028ae05aae34f240bad1362d9436c65150e0` |

The database hashes were independently reproduced by restoring each prefix
with the official
[Litestream v0.5.11 release](https://github.com/benbjohnson/litestream/releases/tag/v0.5.11).
The downloaded Darwin arm64 archive matched its published SHA-256,
`ed96599f041b65d798b705c6029f7673e641df3bf6b9ea21d6ce536f44a2ff5a`.
This one-time oracle qualification is not part of the network-free test suite.

The final database contains
`a=upd5,b=2,c=3,k1=v1,k2=v2,k3=v3,k4=v4,k5=v5`. Hermetic tests verify each
artifact digest and reconstructed image digest. The host SQLite integration
test publishes the entire chain through `ltx_sqlite`, opens the final
generation with the required immutable read-only lease, checks those values,
and runs `PRAGMA integrity_check`.

## Scope and licensing

This corpus proves real Litestream capture compatibility, legacy-frame
decoding, nonzero WAL metadata, file checksums, exact page-index/EOF handling,
TXID continuity, and staged image reconstruction. It does not prove current
flagged-block writer equality, enabled database checksums, sparse page
transitions, or database growth and shrink; separate pinned and SQLite-produced
tests cover those cases.

Celld and Litestream distribute this material under Apache License 2.0. The
applicable notice is retained at
`LICENSE.celld-litestream-apache-2.0` in the repository root.
