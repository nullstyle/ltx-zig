package main

import (
	"bytes"
	"encoding/hex"
	"fmt"
	"os"
	"path/filepath"
)

var fixtureNames = []string{
	"celld_v052_two_page_snapshot",
	"celld_litestream_v0511/replica/ltx/0/0000000000000001-0000000000000001",
	"celld_litestream_v0511/replica/ltx/0/0000000000000002-0000000000000002",
	"celld_litestream_v0511/replica/ltx/0/0000000000000003-0000000000000003",
	"celld_litestream_v0511/replica/ltx/0/0000000000000004-0000000000000004",
	"celld_litestream_v0511/replica/ltx/0/0000000000000005-0000000000000005",
	"celld_litestream_v0511/replica/ltx/0/0000000000000006-0000000000000006",
	"go_v3_empty_snapshot",
	"go_v3_incremental",
	"go_v3_legacy_mixed",
	"go_v3_legacy_unflagged",
	"go_v3_near_lock_page",
	"go_v3_no_checksum",
	"go_v3_snapshot_zero_page",
}

func main() {
	check := false
	var directory string
	switch {
	case len(os.Args) == 2:
		directory = os.Args[1]
	case len(os.Args) == 3 && os.Args[1] == "--check":
		check = true
		directory = os.Args[2]
	default:
		fmt.Fprintln(os.Stderr, "usage: materialize [--check] <fixtures-directory>")
		os.Exit(2)
	}
	for _, name := range fixtureNames {
		if err := materialize(directory, name, check); err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
	}
}

func materialize(directory, name string, check bool) error {
	hexPath := filepath.Join(directory, name+".hex")
	source, err := os.ReadFile(hexPath)
	if err != nil {
		return fmt.Errorf("read %s: %w", hexPath, err)
	}
	compact := source[:0]
	for _, value := range source {
		switch value {
		case ' ', '\t', '\r', '\n':
		default:
			compact = append(compact, value)
		}
	}
	decoded := make([]byte, hex.DecodedLen(len(compact)))
	count, err := hex.Decode(decoded, compact)
	if err != nil {
		return fmt.Errorf("decode %s: %w", hexPath, err)
	}
	outputPath := filepath.Join(directory, name+".ltx")
	if check {
		existing, err := os.ReadFile(outputPath)
		if err != nil {
			return fmt.Errorf("read %s: %w", outputPath, err)
		}
		if !bytes.Equal(existing, decoded[:count]) {
			return fmt.Errorf("%s does not match %s", outputPath, hexPath)
		}
		return nil
	}
	if err := os.WriteFile(outputPath, decoded[:count], 0o644); err != nil {
		return fmt.Errorf("write %s: %w", outputPath, err)
	}
	return nil
}
