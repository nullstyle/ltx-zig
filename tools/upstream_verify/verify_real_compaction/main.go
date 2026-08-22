package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"fmt"
	"io"
	"os"

	"github.com/superfly/ltx"
)

const (
	inputCount             = 4
	expectedDatabaseSHA256 = "27d2e8ad59731445c4798eec1c76146e85bd931383728d89fbd96f91d97b0f6a"
)

func main() {
	if len(os.Args) != inputCount+2 {
		fmt.Fprintln(
			os.Stderr,
			"usage: verify_real_compaction <zig-compacted-ltx> <tx1-ltx> <tx2-ltx> <tx3-ltx> <tx4-ltx>",
		)
		os.Exit(2)
	}
	if err := verify(os.Args[1], os.Args[2:]); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	fmt.Println("pinned Go LTX byte-matched Zig real-fixture compaction output")
}

func verify(zigPath string, inputPaths []string) error {
	readers := make([]io.Reader, inputCount)
	for index, inputPath := range inputPaths {
		data, err := os.ReadFile(inputPath)
		if err != nil {
			return fmt.Errorf("read TX%d input: %w", index+1, err)
		}
		if err := verifyInputHeader(index+1, data); err != nil {
			return err
		}
		readers[index] = bytes.NewReader(data)
	}

	var goOutput bytes.Buffer
	compactor, err := ltx.NewCompactor(&goOutput, readers)
	if err != nil {
		return fmt.Errorf("create pinned Go compactor: %w", err)
	}
	compactor.HeaderFlags = ltx.HeaderFlagNoChecksum
	if err := compactor.Compact(context.Background()); err != nil {
		return fmt.Errorf("compact real fixtures with pinned Go: %w", err)
	}

	zigOutput, err := os.ReadFile(zigPath)
	if err != nil {
		return fmt.Errorf("read Zig compacted output: %w", err)
	}
	if !bytes.Equal(zigOutput, goOutput.Bytes()) {
		return fmt.Errorf(
			"Zig output differs from pinned Go output (Zig %d bytes, Go %d bytes)",
			len(zigOutput), goOutput.Len(),
		)
	}
	if err := verifyCurrentRepresentation(zigOutput); err != nil {
		return err
	}
	return verifyDatabase(zigOutput)
}

func verifyInputHeader(txid int, data []byte) error {
	header, _, err := ltx.DecodeHeader(bytes.NewReader(data))
	if err != nil {
		return fmt.Errorf("decode TX%d input header: %w", txid, err)
	}
	if err := header.Validate(); err != nil {
		return fmt.Errorf("validate TX%d input header: %w", txid, err)
	}
	expectedTXID := ltx.TXID(txid)
	if header.MinTXID != expectedTXID || header.MaxTXID != expectedTXID {
		return fmt.Errorf(
			"TX%d input has transaction range (%s,%s)",
			txid, header.MinTXID, header.MaxTXID,
		)
	}
	if header.Flags != ltx.HeaderFlagNoChecksum {
		return fmt.Errorf("TX%d input has unexpected header flags 0x%08x", txid, header.Flags)
	}
	return nil
}

func verifyCurrentRepresentation(data []byte) error {
	decoder := ltx.NewDecoder(bytes.NewReader(data))
	if err := decoder.DecodeHeader(); err != nil {
		return fmt.Errorf("decode compacted header with pinned Go: %w", err)
	}
	header := decoder.Header()
	if header.Flags != ltx.HeaderFlagNoChecksum {
		return fmt.Errorf("compacted output has unexpected header flags 0x%08x", header.Flags)
	}

	pageData := make([]byte, header.PageSize)
	pageCount := 0
	for {
		var pageHeader ltx.PageHeader
		err := decoder.DecodePage(&pageHeader, pageData)
		if err == io.EOF {
			break
		}
		if err != nil {
			return fmt.Errorf("decode compacted page %d with pinned Go: %w", pageCount, err)
		}
		if pageHeader.Flags != ltx.PageHeaderFlagSize {
			return fmt.Errorf(
				"compacted page %d does not use current flagged raw-LZ4 representation: flags 0x%04x",
				pageHeader.Pgno, pageHeader.Flags,
			)
		}
		pageCount++
	}
	if pageCount == 0 {
		return fmt.Errorf("compacted output contains no pages")
	}
	if err := decoder.Close(); err != nil {
		return fmt.Errorf("verify compacted output with pinned Go: %w", err)
	}
	return nil
}

func verifyDatabase(data []byte) error {
	var database bytes.Buffer
	decoder := ltx.NewDecoder(bytes.NewReader(data))
	if err := decoder.DecodeDatabaseTo(&database); err != nil {
		return fmt.Errorf("decode compacted database with pinned Go: %w", err)
	}
	digest := sha256.Sum256(database.Bytes())
	if actual := fmt.Sprintf("%x", digest); actual != expectedDatabaseSHA256 {
		return fmt.Errorf(
			"compacted database SHA-256 mismatch: got %s, want %s",
			actual, expectedDatabaseSHA256,
		)
	}
	return nil
}
