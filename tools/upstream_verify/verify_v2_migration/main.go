package main

import (
	"bytes"
	"crypto/sha256"
	"encoding/binary"
	"fmt"
	"io"
	"os"

	"github.com/superfly/ltx"
)

const (
	maxLTXBytes          = 4096
	migratedDatabaseHash = "d83e04db4d5ed75b3d5cd7d5b910690162c26cfbd24584f8f8e3bbec607aa475"
	sqliteDatabaseHash   = "2d3f4873f9cbd65802382dc11067c1e52d72cdaa464bda1f5072faac002e95f5"
)

func main() {
	if len(os.Args) != 4 {
		fmt.Fprintln(os.Stderr, "usage: verify_v2_migration <v2-only-ltx> <mixed-ltx> <sqlite-empty-ltx>")
		os.Exit(2)
	}
	migration, err := encodeExpected(expectedMigration())
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	sqlite, err := encodeExpected(expectedSQLiteMigration())
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	cases := []struct {
		name, path, databaseHash string
		expected                 []byte
	}{
		{name: "v2-only", path: os.Args[1], expected: migration, databaseHash: migratedDatabaseHash},
		{name: "mixed", path: os.Args[2], expected: migration, databaseHash: migratedDatabaseHash},
		{name: "sqlite-empty", path: os.Args[3], expected: sqlite, databaseHash: sqliteDatabaseHash},
	}
	for _, fixture := range cases {
		if err := verify(fixture.name, fixture.path, fixture.expected, fixture.databaseHash); err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
	}
	fmt.Println("pinned current Go LTX byte-matched Zig v2-only, mixed, and SQLite v2 migrations")
}

func verify(name, path string, expected []byte, databaseHash string) error {
	actual, err := readBoundedFile(path, maxLTXBytes)
	if err != nil {
		return fmt.Errorf("%s: read Zig output: %w", name, err)
	}
	if !bytes.Equal(actual, expected) {
		return fmt.Errorf(
			"%s: Zig migration differs from pinned current Go output (Zig %d bytes, Go %d bytes)",
			name, len(actual), len(expected),
		)
	}
	var decoded bytes.Buffer
	decoder := ltx.NewDecoder(bytes.NewReader(actual))
	if err := decoder.DecodeDatabaseTo(&decoded); err != nil {
		return fmt.Errorf("%s: decode Zig migration with pinned current Go: %w", name, err)
	}
	digest := fmt.Sprintf("%x", sha256.Sum256(decoded.Bytes()))
	if digest != databaseHash {
		return fmt.Errorf("%s: database SHA-256 mismatch: got %s, want %s", name, digest, databaseHash)
	}
	return nil
}

func encodeExpected(spec *ltx.FileSpec) ([]byte, error) {
	var output bytes.Buffer
	if _, err := spec.WriteTo(&output); err != nil {
		return nil, fmt.Errorf("encode expected current v3 output: %w", err)
	}
	if output.Len() > maxLTXBytes {
		return nil, fmt.Errorf("expected current v3 output exceeds %d bytes", maxLTXBytes)
	}
	return output.Bytes(), nil
}

func expectedMigration() *ltx.FileSpec {
	pages := []ltx.PageSpec{
		page(1, bytes.Repeat([]byte{0x31}, 512)),
		page(2, xorshiftPage()),
		page(3, bytes.Repeat([]byte{0x33}, 512)),
	}
	return &ltx.FileSpec{
		Header: ltx.Header{
			Version: ltx.Version, PageSize: 512, Commit: 3,
			MinTXID: 1, MaxTXID: 4, Timestamp: -1000,
		},
		Pages:   pages,
		Trailer: ltx.Trailer{PostApplyChecksum: databaseChecksum(pages...)},
	}
}

func expectedSQLiteMigration() *ltx.FileSpec {
	pages := []ltx.PageSpec{page(1, sqliteEmptyPage())}
	return &ltx.FileSpec{
		Header: ltx.Header{
			Version: ltx.Version, PageSize: 512, Commit: 1,
			MinTXID: 1, MaxTXID: 1,
		},
		Pages:   pages,
		Trailer: ltx.Trailer{PostApplyChecksum: databaseChecksum(pages...)},
	}
}

func sqliteEmptyPage() []byte {
	data := make([]byte, 512)
	copy(data[0:16], "SQLite format 3\x00")
	binary.BigEndian.PutUint16(data[16:18], 512)
	data[18], data[19] = 1, 1
	data[21], data[22], data[23] = 64, 32, 32
	binary.BigEndian.PutUint32(data[24:28], 1)
	binary.BigEndian.PutUint32(data[28:32], 1)
	binary.BigEndian.PutUint32(data[40:44], 1)
	binary.BigEndian.PutUint32(data[44:48], 4)
	binary.BigEndian.PutUint32(data[56:60], 1)
	binary.BigEndian.PutUint32(data[92:96], 1)
	binary.BigEndian.PutUint32(data[96:100], 3_051_000)
	data[100] = 13
	binary.BigEndian.PutUint16(data[105:107], 512)
	return data
}

func xorshiftPage() []byte {
	data := make([]byte, 512)
	state := uint32(0x9e3779b9)
	for index := range data {
		state ^= state << 13
		state ^= state >> 17
		state ^= state << 5
		data[index] = byte(state)
	}
	return data
}

func databaseChecksum(pages ...ltx.PageSpec) ltx.Checksum {
	checksum := ltx.ChecksumFlag
	for _, page := range pages {
		checksum = ltx.ChecksumFlag | (checksum ^ ltx.ChecksumPage(page.Header.Pgno, page.Data))
	}
	return checksum
}

func page(number uint32, data []byte) ltx.PageSpec {
	return ltx.PageSpec{Header: ltx.PageHeader{Pgno: number}, Data: data}
}

func readBoundedFile(path string, maxBytes int64) ([]byte, error) {
	file, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil {
		return nil, err
	}
	if !info.Mode().IsRegular() || info.Size() < 0 || info.Size() > maxBytes {
		return nil, fmt.Errorf("invalid file size %d (maximum %d)", info.Size(), maxBytes)
	}
	data, err := io.ReadAll(io.LimitReader(file, maxBytes+1))
	if err != nil {
		return nil, err
	}
	if int64(len(data)) != info.Size() || int64(len(data)) > maxBytes {
		return nil, fmt.Errorf("file changed while reading")
	}
	return data, nil
}
