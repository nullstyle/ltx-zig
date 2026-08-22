// The v2 wire oracle is superfly/ltx v0.4.0 at commit
// 2af9b0cb7a6eebfb59c2ca76acc4ae3adf4b6a09.
package main

import (
	"bytes"
	"encoding/hex"
	"fmt"
	"os"
	"path/filepath"

	"github.com/superfly/ltx"
)

const hexLineBytes = 64

var fixtures = []struct {
	name     string
	basename string
}{
	{name: "mixed", basename: "go_v2_mixed_snapshot"},
	{name: "empty", basename: "go_v2_empty_snapshot"},
	{name: "sqlite-empty", basename: "go_v2_sqlite_empty"},
	{name: "incremental", basename: "go_v2_incremental"},
	{name: "no-checksum", basename: "go_v2_no_checksum"},
	{name: "near-lock", basename: "go_v2_near_lock_page"},
}

func main() {
	if err := run(os.Args[1:]); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func run(args []string) error {
	switch {
	case len(args) == 1:
		data, err := generate(args[0])
		if err != nil {
			return err
		}
		_, err = os.Stdout.Write(data)
		return err
	case len(args) == 2 && args[0] == "--hex":
		data, err := generate(args[1])
		if err != nil {
			return err
		}
		_, err = os.Stdout.Write(formatHex(data))
		return err
	case len(args) == 2 && args[0] == "--write":
		return writeAll(args[1])
	case len(args) == 2 && args[0] == "--check":
		return checkAll(args[1])
	default:
		return fmt.Errorf("usage: v2_fixturegen [--hex] <mixed|empty|sqlite-empty|incremental|no-checksum|near-lock> | [--write|--check] <fixtures-directory>")
	}
}

func generate(name string) ([]byte, error) {
	spec, err := fixture(name)
	if err != nil {
		return nil, err
	}
	var output bytes.Buffer
	if _, err := spec.WriteTo(&output); err != nil {
		return nil, fmt.Errorf("generate %s: %w", name, err)
	}
	return output.Bytes(), nil
}

func writeAll(directory string) error {
	for _, entry := range fixtures {
		data, err := generate(entry.name)
		if err != nil {
			return err
		}
		binaryPath := filepath.Join(directory, entry.basename+".ltx")
		if err := os.WriteFile(binaryPath, data, 0o644); err != nil {
			return fmt.Errorf("write %s: %w", binaryPath, err)
		}
		hexPath := filepath.Join(directory, entry.basename+".hex")
		if err := os.WriteFile(hexPath, formatHex(data), 0o644); err != nil {
			return fmt.Errorf("write %s: %w", hexPath, err)
		}
	}
	return nil
}

func checkAll(directory string) error {
	for _, entry := range fixtures {
		data, err := generate(entry.name)
		if err != nil {
			return err
		}
		if err := checkFile(filepath.Join(directory, entry.basename+".ltx"), data); err != nil {
			return err
		}
		if err := checkFile(filepath.Join(directory, entry.basename+".hex"), formatHex(data)); err != nil {
			return err
		}
	}
	return nil
}

func checkFile(path string, expected []byte) error {
	actual, err := os.ReadFile(path)
	if err != nil {
		return fmt.Errorf("read %s: %w", path, err)
	}
	if !bytes.Equal(actual, expected) {
		return fmt.Errorf("generated fixture does not match %s", path)
	}
	return nil
}

func formatHex(data []byte) []byte {
	encoded := make([]byte, hex.EncodedLen(len(data)))
	hex.Encode(encoded, data)
	lineBytes := hexLineBytes * 2
	lineCount := (len(encoded) + lineBytes - 1) / lineBytes
	formatted := make([]byte, 0, len(encoded)+lineCount)
	for len(encoded) > 0 {
		count := min(len(encoded), lineBytes)
		formatted = append(formatted, encoded[:count]...)
		formatted = append(formatted, '\n')
		encoded = encoded[count:]
	}
	return formatted
}

func fixture(name string) (*ltx.FileSpec, error) {
	switch name {
	case "mixed":
		return mixedSnapshot(), nil
	case "empty":
		return emptySnapshot(), nil
	case "sqlite-empty":
		return sqliteEmptySnapshot(), nil
	case "incremental":
		return incremental(), nil
	case "no-checksum":
		return noChecksum(), nil
	case "near-lock":
		return nearLock(), nil
	default:
		return nil, fmt.Errorf("unknown fixture %q", name)
	}
}

func mixedSnapshot() *ltx.FileSpec {
	pages := []ltx.PageSpec{
		{Header: ltx.PageHeader{Pgno: 1}, Data: make([]byte, 512)},
		{Header: ltx.PageHeader{Pgno: 2}, Data: xorshiftPage()},
	}
	return snapshot(512, pages)
}

func emptySnapshot() *ltx.FileSpec {
	return snapshot(512, nil)
}

func sqliteEmptySnapshot() *ltx.FileSpec {
	page := make([]byte, 512)
	copy(page[0:16], "SQLite format 3\x00")
	putUint16(page[16:18], 512)
	page[18] = 1
	page[19] = 1
	page[21] = 64
	page[22] = 32
	page[23] = 32
	putUint32(page[24:28], 1)
	putUint32(page[28:32], 1)
	putUint32(page[40:44], 1)
	putUint32(page[44:48], 4)
	putUint32(page[56:60], 1)
	putUint32(page[92:96], 1)
	putUint32(page[96:100], 3_051_000)
	page[100] = 13
	putUint16(page[105:107], 512)
	return snapshot(512, []ltx.PageSpec{
		{Header: ltx.PageHeader{Pgno: 1}, Data: page},
	})
}

func incremental() *ltx.FileSpec {
	page1 := filled(512, 0x31)
	page2 := xorshiftPage()
	page3 := filled(512, 0x33)
	preApplyChecksum := databaseChecksum([]ltx.PageSpec{
		{Header: ltx.PageHeader{Pgno: 1}, Data: make([]byte, 512)},
		{Header: ltx.PageHeader{Pgno: 2}, Data: page2},
	})
	postApplyChecksum := databaseChecksum([]ltx.PageSpec{
		{Header: ltx.PageHeader{Pgno: 1}, Data: page1},
		{Header: ltx.PageHeader{Pgno: 2}, Data: page2},
		{Header: ltx.PageHeader{Pgno: 3}, Data: page3},
	})
	return &ltx.FileSpec{
		Header: ltx.Header{
			Version:          ltx.Version,
			PageSize:         512,
			Commit:           3,
			MinTXID:          2,
			MaxTXID:          4,
			Timestamp:        -1000,
			PreApplyChecksum: preApplyChecksum,
		},
		Pages: []ltx.PageSpec{
			{Header: ltx.PageHeader{Pgno: 1}, Data: page1},
			{Header: ltx.PageHeader{Pgno: 3}, Data: page3},
		},
		Trailer: ltx.Trailer{PostApplyChecksum: postApplyChecksum},
	}
}

func noChecksum() *ltx.FileSpec {
	return &ltx.FileSpec{
		Header: ltx.Header{
			Version:   ltx.Version,
			Flags:     ltx.HeaderFlagNoChecksum,
			PageSize:  4096,
			Commit:    2,
			MinTXID:   5,
			MaxTXID:   5,
			Timestamp: 2000,
		},
		Pages: []ltx.PageSpec{
			{Header: ltx.PageHeader{Pgno: 2}, Data: filled(4096, 0xa5)},
		},
		Trailer: ltx.Trailer{PostApplyChecksum: 0},
	}
}

func nearLock() *ltx.FileSpec {
	return &ltx.FileSpec{
		Header: ltx.Header{
			Version:          ltx.Version,
			PageSize:         65_536,
			Commit:           16_386,
			MinTXID:          7,
			MaxTXID:          8,
			Timestamp:        3000,
			PreApplyChecksum: ltx.ChecksumFlag | 0x111,
		},
		Pages: []ltx.PageSpec{
			{Header: ltx.PageHeader{Pgno: 16_384}, Data: filled(65_536, 0x84)},
			{Header: ltx.PageHeader{Pgno: 16_386}, Data: filled(65_536, 0x86)},
		},
		Trailer: ltx.Trailer{PostApplyChecksum: ltx.ChecksumFlag | 0x222},
	}
}

func snapshot(pageSize uint32, pages []ltx.PageSpec) *ltx.FileSpec {
	return &ltx.FileSpec{
		Header: ltx.Header{
			Version:  ltx.Version,
			PageSize: pageSize,
			Commit:   uint32(len(pages)),
			MinTXID:  1,
			MaxTXID:  1,
		},
		Pages:   pages,
		Trailer: ltx.Trailer{PostApplyChecksum: databaseChecksum(pages)},
	}
}

func databaseChecksum(pages []ltx.PageSpec) ltx.Checksum {
	checksum := ltx.ChecksumFlag
	for _, page := range pages {
		checksum = ltx.ChecksumFlag |
			(checksum ^ ltx.ChecksumPage(page.Header.Pgno, page.Data))
	}
	return checksum
}

func filled(size int, value byte) []byte {
	return bytes.Repeat([]byte{value}, size)
}

func putUint16(destination []byte, value uint16) {
	destination[0] = byte(value >> 8)
	destination[1] = byte(value)
}

func putUint32(destination []byte, value uint32) {
	destination[0] = byte(value >> 24)
	destination[1] = byte(value >> 16)
	destination[2] = byte(value >> 8)
	destination[3] = byte(value)
}

func xorshiftPage() []byte {
	page := make([]byte, 512)
	state := uint32(0x9e3779b9)
	for index := range page {
		state ^= state << 13
		state ^= state >> 17
		state ^= state << 5
		page[index] = byte(state)
	}
	return page
}
