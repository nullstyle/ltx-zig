package main

import (
	"fmt"
	"os"

	"github.com/superfly/ltx"
)

func main() {
	if len(os.Args) != 2 {
		fmt.Fprintln(os.Stderr, "usage: fixturegen <snapshot-zero|empty|incremental|no-checksum|near-lock>")
		os.Exit(2)
	}
	spec, err := fixture(os.Args[1])
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(2)
	}
	if _, err := spec.WriteTo(os.Stdout); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
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
