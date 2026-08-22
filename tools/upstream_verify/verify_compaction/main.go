package main

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"os"

	"github.com/superfly/ltx"
)

const pageSize = 512

type expectedOutput struct {
	header      ltx.Header
	pages       []ltx.PageSpec
	post        ltx.Checksum
	headerFlags uint32
}

func main() {
	if len(os.Args) != 4 {
		fmt.Fprintln(os.Stderr, "usage: verify_compaction <merge-ltx> <deletion-ltx> <no-checksum-ltx>")
		os.Exit(2)
	}
	if err := verifyFixture("merge", os.Args[1], mergeInputs); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	if err := verifyFixture("deletion", os.Args[2], deletionInputs); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	if err := verifyFixture("no-checksum", os.Args[3], noChecksumInputs); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	fmt.Println("pinned Go LTX byte-matched Zig compaction output")
}

func verifyFixture(
	name string,
	zigPath string,
	fixture func() ([]*ltx.FileSpec, expectedOutput),
) error {
	inputs, expected := fixture()
	buffers := make([]bytes.Buffer, len(inputs))
	readers := make([]io.Reader, len(inputs))
	for index, input := range inputs {
		if _, err := input.WriteTo(&buffers[index]); err != nil {
			return fmt.Errorf("%s: encode Go input %d: %w", name, index, err)
		}
		readers[index] = &buffers[index]
	}

	var goOutput bytes.Buffer
	compactor, err := ltx.NewCompactor(&goOutput, readers)
	if err != nil {
		return fmt.Errorf("%s: create Go compactor: %w", name, err)
	}
	compactor.HeaderFlags = expected.headerFlags
	if err := compactor.Compact(context.Background()); err != nil {
		return fmt.Errorf("%s: compact with Go: %w", name, err)
	}
	zigOutput, err := os.ReadFile(zigPath)
	if err != nil {
		return fmt.Errorf("%s: read Zig output: %w", name, err)
	}
	if !bytes.Equal(zigOutput, goOutput.Bytes()) {
		return fmt.Errorf(
			"%s: Zig output differs from pinned Go output (Zig %d bytes, Go %d bytes)",
			name, len(zigOutput), goOutput.Len(),
		)
	}
	return verifySemantics(name, zigOutput, expected)
}

func verifySemantics(name string, data []byte, expected expectedOutput) error {
	var actual ltx.FileSpec
	if _, err := actual.ReadFrom(bytes.NewReader(data)); err != nil {
		return fmt.Errorf("%s: decode Zig output with Go: %w", name, err)
	}
	if actual.Header != expected.header {
		return fmt.Errorf("%s: header mismatch: got %#v, want %#v", name, actual.Header, expected.header)
	}
	if actual.Trailer.PostApplyChecksum != expected.post {
		return fmt.Errorf(
			"%s: post-apply checksum mismatch: got %016x, want %016x",
			name, actual.Trailer.PostApplyChecksum, expected.post,
		)
	}
	if len(actual.Pages) != len(expected.pages) {
		return fmt.Errorf("%s: page count mismatch: got %d, want %d", name, len(actual.Pages), len(expected.pages))
	}
	for index := range expected.pages {
		got, want := actual.Pages[index], expected.pages[index]
		if got.Header.Pgno != want.Header.Pgno || got.Header.Flags != ltx.PageHeaderFlagSize {
			return fmt.Errorf("%s: unexpected page header %d: %#v", name, index, got.Header)
		}
		if !bytes.Equal(got.Data, want.Data) {
			return fmt.Errorf("%s: unexpected page data %d", name, index)
		}
	}
	return nil
}

func mergeInputs() ([]*ltx.FileSpec, expectedOutput) {
	page11, page12, page13 := filled(0x11), filled(0x12), filled(0x13)
	page21, page24, page32 := filled(0x21), filled(0x24), filled(0x32)
	postOne := databaseChecksum(page(1, page11), page(2, page12), page(3, page13))
	postTwo := databaseChecksum(page(1, page21), page(2, page12), page(3, page13), page(4, page24))
	postThree := databaseChecksum(page(1, page21), page(2, page32))

	inputs := []*ltx.FileSpec{
		fileSpec(metadataHeader(1, 3, 1000, 0, 100), postOne,
			page(1, page11), page(2, page12), page(3, page13)),
		fileSpec(metadataHeader(2, 4, 2000, postOne, 200), postTwo,
			page(1, page21), page(4, page24)),
		fileSpec(metadataHeader(3, 2, 3000, postTwo, 300), postThree,
			page(2, page32)),
	}
	expected := expectedOutput{
		header: outputHeader(1, 3, 2, 3000),
		pages:  []ltx.PageSpec{page(1, page21), page(2, page32)},
		post:   postThree,
	}
	return inputs, expected
}

func deletionInputs() ([]*ltx.FileSpec, expectedOutput) {
	page41 := filled(0x41)
	postOne := databaseChecksum(page(1, page41))
	inputs := []*ltx.FileSpec{
		fileSpec(metadataHeader(1, 1, 4000, 0, 400), postOne, page(1, page41)),
		fileSpec(metadataHeader(2, 0, 5000, postOne, 800), ltx.ChecksumFlag),
	}
	expected := expectedOutput{
		header: outputHeader(1, 2, 0, 5000),
		post:   ltx.ChecksumFlag,
	}
	return inputs, expected
}

func noChecksumInputs() ([]*ltx.FileSpec, expectedOutput) {
	page61, page62, page72 := filled(0x61), filled(0x62), filled(0x72)
	inputs := []*ltx.FileSpec{
		fileSpec(noChecksumHeader(4, 2, 6000, 600), 0,
			page(1, page61), page(2, page62)),
		fileSpec(noChecksumHeader(5, 2, 7000, 700), 0,
			page(2, page72)),
	}
	header := outputHeader(4, 5, 2, 7000)
	header.Flags = ltx.HeaderFlagNoChecksum
	expected := expectedOutput{
		header:      header,
		pages:       []ltx.PageSpec{page(1, page61), page(2, page72)},
		headerFlags: ltx.HeaderFlagNoChecksum,
	}
	return inputs, expected
}

func fileSpec(header ltx.Header, post ltx.Checksum, pages ...ltx.PageSpec) *ltx.FileSpec {
	return &ltx.FileSpec{
		Header:  header,
		Pages:   pages,
		Trailer: ltx.Trailer{PostApplyChecksum: post},
	}
}

func metadataHeader(
	txid ltx.TXID,
	commit uint32,
	timestamp int64,
	pre ltx.Checksum,
	metadataBase int64,
) ltx.Header {
	return ltx.Header{
		Version:          ltx.Version,
		PageSize:         pageSize,
		Commit:           commit,
		MinTXID:          txid,
		MaxTXID:          txid,
		Timestamp:        timestamp,
		PreApplyChecksum: pre,
		WALOffset:        metadataBase,
		WALSize:          metadataBase + 50,
		WALSalt1:         uint32(metadataBase + 1),
		WALSalt2:         uint32(metadataBase + 2),
		NodeID:           uint64(metadataBase + 3),
	}
}

func noChecksumHeader(
	txid ltx.TXID,
	commit uint32,
	timestamp int64,
	metadataBase int64,
) ltx.Header {
	header := metadataHeader(txid, commit, timestamp, 0, metadataBase)
	header.Flags = ltx.HeaderFlagNoChecksum
	return header
}

func outputHeader(min, max ltx.TXID, commit uint32, timestamp int64) ltx.Header {
	return ltx.Header{
		Version:   ltx.Version,
		PageSize:  pageSize,
		Commit:    commit,
		MinTXID:   min,
		MaxTXID:   max,
		Timestamp: timestamp,
	}
}

func page(number uint32, data []byte) ltx.PageSpec {
	return ltx.PageSpec{Header: ltx.PageHeader{Pgno: number}, Data: data}
}

func filled(value byte) []byte {
	return bytes.Repeat([]byte{value}, pageSize)
}

func databaseChecksum(pages ...ltx.PageSpec) ltx.Checksum {
	checksum := ltx.ChecksumFlag
	for _, page := range pages {
		checksum = ltx.ChecksumFlag | (checksum ^ ltx.ChecksumPage(page.Header.Pgno, page.Data))
	}
	return checksum
}
