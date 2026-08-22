package main

import (
	"bytes"
	"fmt"
	"io"
	"os"
	"path/filepath"

	"github.com/superfly/ltx"
)

var fixtures = []struct {
	name     string
	basename string
}{
	{name: "snapshot-zero", basename: "go_v3_snapshot_zero_page"},
	{name: "empty", basename: "go_v3_empty_snapshot"},
	{name: "incremental", basename: "go_v3_incremental"},
	{name: "no-checksum", basename: "go_v3_no_checksum"},
	{name: "near-lock", basename: "go_v3_near_lock_page"},
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
	case len(args) == 2 && args[0] == "--check":
		return checkAll(args[1])
	default:
		return fmt.Errorf("usage: fixturegen <snapshot-zero|empty|incremental|no-checksum|near-lock> | --check <fixtures-directory>")
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

func checkAll(directory string) error {
	for _, entry := range fixtures {
		expected, err := generate(entry.name)
		if err != nil {
			return err
		}
		path := filepath.Join(directory, entry.basename+".ltx")
		actual, err := readExactFile(path, int64(len(expected)))
		if err != nil {
			return err
		}
		if !bytes.Equal(actual, expected) {
			return fmt.Errorf("generated fixture does not match %s", path)
		}
	}
	return nil
}

func readExactFile(path string, expectedBytes int64) ([]byte, error) {
	file, err := os.Open(path)
	if err != nil {
		return nil, fmt.Errorf("open %s: %w", path, err)
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil {
		return nil, fmt.Errorf("stat %s: %w", path, err)
	}
	if !info.Mode().IsRegular() || info.Size() != expectedBytes {
		return nil, fmt.Errorf("%s has size %d, expected %d", path, info.Size(), expectedBytes)
	}
	actual, err := io.ReadAll(io.LimitReader(file, expectedBytes+1))
	if err != nil {
		return nil, fmt.Errorf("read %s: %w", path, err)
	}
	if int64(len(actual)) != expectedBytes {
		return nil, fmt.Errorf("%s changed while reading", path)
	}
	return actual, nil
}

func fixture(name string) (*ltx.FileSpec, error) {
	switch name {
	case "snapshot-zero":
		page := filled(512, 0)
		return &ltx.FileSpec{
			Header: ltx.Header{
				Version:  ltx.Version,
				PageSize: 512,
				Commit:   1,
				MinTXID:  1,
				MaxTXID:  1,
			},
			Pages: []ltx.PageSpec{
				{Header: ltx.PageHeader{Pgno: 1}, Data: page},
			},
			Trailer: ltx.Trailer{PostApplyChecksum: ltx.ChecksumPage(1, page)},
		}, nil
	case "empty":
		return &ltx.FileSpec{
			Header: ltx.Header{
				Version:  ltx.Version,
				PageSize: 512,
				Commit:   0,
				MinTXID:  1,
				MaxTXID:  1,
			},
			Trailer: ltx.Trailer{PostApplyChecksum: ltx.ChecksumFlag},
		}, nil
	case "incremental":
		return &ltx.FileSpec{
			Header: ltx.Header{
				Version:          ltx.Version,
				PageSize:         512,
				Commit:           3,
				MinTXID:          2,
				MaxTXID:          4,
				Timestamp:        -1000,
				PreApplyChecksum: ltx.ChecksumFlag | 0x1234,
			},
			Pages: []ltx.PageSpec{
				{Header: ltx.PageHeader{Pgno: 1}, Data: filled(512, 0x31)},
				{Header: ltx.PageHeader{Pgno: 3}, Data: filled(512, 0x33)},
			},
			Trailer: ltx.Trailer{PostApplyChecksum: ltx.ChecksumFlag | 0x5678},
		}, nil
	case "no-checksum":
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
		}, nil
	case "near-lock":
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
		}, nil
	default:
		return nil, fmt.Errorf("unknown fixture %q", name)
	}
}

func filled(size int, value byte) []byte {
	data := make([]byte, size)
	for index := range data {
		data[index] = value
	}
	return data
}
