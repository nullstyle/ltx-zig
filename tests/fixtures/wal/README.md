# WAL fixture manifest

These binary SQLite WAL fixtures are immutable captured input for the
`ltx_wal` module tests. They are copied verbatim from the pinned
[`denoland/celld` LTX crate](https://github.com/denoland/celld/tree/89e4ffc53a14ecb496d2ca5014ff9d19b0061ad9/crates/ltx)
at commit `89e4ffc53a14ecb496d2ca5014ff9d19b0061ad9`, which itself vendors
them from Litestream v0.5.11 and real SQLite 3.51.0. They are not generated
locally. The upstream license notice is retained in
[`LICENSE.celld-litestream-apache-2.0`](../../LICENSE.celld-litestream-apache-2.0).

| File | Upstream source | Shape | Binary SHA-256 |
| --- | --- | --- | --- |
| `go_ok.wal` | `reference/litestream-go/testdata/wal-reader/ok/wal` | 12,392 bytes; page size 4096; 3 frames: page 1, then a two-page transaction committing at 2 with page 2 rewritten | `49333017938bb6c33b292a4a86fc3320bb5895f3182d430d6f0f15b9268014de` |
| `go_salt_mismatch.wal` | `reference/litestream-go/testdata/wal-reader/salt-mismatch/wal` | First frame valid; second frame carries foreign salts | `4bd7199eab6e798eef20b05c9ea74e791989a222ba6f5b899805c854c94512c4` |
| `go_frame_checksum_mismatch.wal` | `reference/litestream-go/testdata/wal-reader/frame-checksum-mismatch/wal` | First frame valid; second frame breaks the cumulative checksum | `368521166ba39941b743e1b1ff9ac9b44f65a5482d90500de08ab0c5a36b0eb5` |
| `go_frame_salts.wal` | `reference/litestream-go/testdata/wal-reader/frame-salts/wal` | 41,232 bytes; 10 frames carrying exactly three distinct salt pairs | `279f45e8753327d5c4326f314f9eccb8a85edb6de624a8383d1dfbba2fc7d11b` |
| `celld_sample.wal` | `tests/fixtures/golden/sample.wal` | 16,512 bytes; page size 4096; header salts `0x9bf29a02`/`0x68670130`; exactly 4 checksum-valid frames from SQLite 3.51.0 | `7329379064af2b55e1a9f1d8672bef45528eeecc9c015a0035b42e1d269eabbd` |

Every asserted frame fact (page numbers, commit values, page-data slices,
offsets, salt sets) is a ported known answer from Litestream v0.5.11
`wal_reader_test.go` or the Celld golden-suite assertions over `sample.wal`.
A checksum failure in these tests means the port is wrong, not the fixture.
