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

const matrixCaseCount = 5
const matrixInputCount = 12
const maxLTXBytes = 384 * 1024
const maxDatabaseBytes = 5 * 65_536

type boundedBuffer struct {
	bytes.Buffer
	maxBytes int
}

func newBoundedBuffer(maxBytes int) *boundedBuffer {
	return &boundedBuffer{maxBytes: maxBytes}
}

func (buffer *boundedBuffer) Write(data []byte) (int, error) {
	if len(data) > buffer.maxBytes-buffer.Len() {
		return 0, fmt.Errorf("bounded output exceeds %d bytes", buffer.maxBytes)
	}
	return buffer.Buffer.Write(data)
}

type expectedOutput struct {
	header         ltx.Header
	pages          []ltx.PageSpec
	post           ltx.Checksum
	headerFlags    uint32
	databaseSHA256 string
}

type matrixCase struct {
	name   string
	inputs []*ltx.FileSpec
	legacy bool
	want   expectedOutput
}

func main() {
	if len(os.Args) != matrixCaseCount+matrixInputCount+2 {
		fmt.Fprintln(os.Stderr, "usage: verify_valid_chain <output inputs...>... <legacy-fixture>")
		os.Exit(2)
	}
	legacy, err := readBoundedFile(os.Args[len(os.Args)-1], maxLTXBytes)
	if err != nil {
		fmt.Fprintln(os.Stderr, fmt.Errorf("read legacy fixture: %w", err))
		os.Exit(1)
	}
	cases := validChainCases()
	argumentIndex := 1
	for _, fixture := range cases {
		inputCount := len(fixture.inputs)
		if fixture.legacy {
			inputCount++
		}
		outputPath := os.Args[argumentIndex]
		argumentIndex++
		inputPaths := os.Args[argumentIndex : argumentIndex+inputCount]
		argumentIndex += inputCount
		if err := verifyCase(fixture, outputPath, inputPaths, legacy); err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
	}
	if argumentIndex != len(os.Args)-1 {
		fmt.Fprintln(os.Stderr, "internal argument routing mismatch")
		os.Exit(1)
	}
	fmt.Println("pinned Go LTX byte-matched five Zig valid-chain compactions")
}

func verifyCase(fixture matrixCase, zigPath string, inputPaths []string, legacy []byte) error {
	readers, err := verifyInputs(fixture, inputPaths, legacy)
	if err != nil {
		return err
	}
	goOutput := newBoundedBuffer(maxLTXBytes)
	compactor, err := ltx.NewCompactor(goOutput, readers)
	if err != nil {
		return fmt.Errorf("%s: create pinned Go compactor: %w", fixture.name, err)
	}
	compactor.HeaderFlags = fixture.want.headerFlags
	if err := compactor.Compact(context.Background()); err != nil {
		return fmt.Errorf("%s: compact with pinned Go: %w", fixture.name, err)
	}
	zigOutput, err := readBoundedFile(zigPath, maxLTXBytes)
	if err != nil {
		return fmt.Errorf("%s: read Zig output: %w", fixture.name, err)
	}
	if !bytes.Equal(zigOutput, goOutput.Bytes()) {
		return fmt.Errorf(
			"%s: Zig output differs from pinned Go output (Zig %d bytes, Go %d bytes)",
			fixture.name, len(zigOutput), goOutput.Len(),
		)
	}
	if err := verifySemantics(fixture.name, zigOutput, fixture.want); err != nil {
		return err
	}
	return verifyDatabase(fixture.name, zigOutput, fixture.want.databaseSHA256)
}

func verifyInputs(fixture matrixCase, paths []string, legacy []byte) ([]io.Reader, error) {
	expectedCount := len(fixture.inputs)
	if fixture.legacy {
		expectedCount++
	}
	if len(paths) != expectedCount {
		return nil, fmt.Errorf("%s: got %d Zig inputs, want %d", fixture.name, len(paths), expectedCount)
	}
	readers := make([]io.Reader, 0, expectedCount)
	pathIndex := 0
	if fixture.legacy {
		if err := verifyLegacySnapshot(legacy); err != nil {
			return nil, fmt.Errorf("%s: %w", fixture.name, err)
		}
		zigLegacy, err := readBoundedFile(paths[pathIndex], maxLTXBytes)
		if err != nil {
			return nil, fmt.Errorf("%s: read Zig legacy input: %w", fixture.name, err)
		}
		if !bytes.Equal(zigLegacy, legacy) {
			return nil, fmt.Errorf("%s: Zig legacy input differs from committed fixture", fixture.name)
		}
		readers = append(readers, bytes.NewReader(zigLegacy))
		pathIndex++
	}
	for index, input := range fixture.inputs {
		expected := newBoundedBuffer(maxLTXBytes)
		if _, err := input.WriteTo(expected); err != nil {
			return nil, fmt.Errorf("%s: encode Go input %d: %w", fixture.name, index, err)
		}
		zigInput, err := readBoundedFile(paths[pathIndex], maxLTXBytes)
		if err != nil {
			return nil, fmt.Errorf("%s: read Zig input %d: %w", fixture.name, index, err)
		}
		if !bytes.Equal(zigInput, expected.Bytes()) {
			return nil, fmt.Errorf("%s: Zig input %d differs from pinned Go bytes", fixture.name, index)
		}
		readers = append(readers, bytes.NewReader(zigInput))
		pathIndex++
	}
	return readers, nil
}

func verifyLegacySnapshot(data []byte) error {
	var spec ltx.FileSpec
	if _, err := spec.ReadFrom(bytes.NewReader(data)); err != nil {
		return fmt.Errorf("decode historical input: %w", err)
	}
	if spec.Header.MinTXID != 1 || spec.Header.MaxTXID != 1 ||
		spec.Header.Commit != 1 || spec.Header.PageSize != 512 || len(spec.Pages) != 1 {
		return fmt.Errorf("historical input has unexpected shape")
	}
	if spec.Pages[0].Header.Flags != 0 || !bytes.Equal(spec.Pages[0].Data, filled(512, 0)) {
		return fmt.Errorf("historical input is not the expected legacy zero page")
	}
	return nil
}

func verifySemantics(name string, data []byte, want expectedOutput) error {
	var actual ltx.FileSpec
	if _, err := actual.ReadFrom(bytes.NewReader(data)); err != nil {
		return fmt.Errorf("%s: decode Zig output with pinned Go: %w", name, err)
	}
	if actual.Header != want.header {
		return fmt.Errorf("%s: header mismatch: got %#v, want %#v", name, actual.Header, want.header)
	}
	if actual.Trailer.PostApplyChecksum != want.post {
		return fmt.Errorf(
			"%s: post-apply checksum mismatch: got %016x, want %016x",
			name, actual.Trailer.PostApplyChecksum, want.post,
		)
	}
	if len(actual.Pages) != len(want.pages) {
		return fmt.Errorf("%s: page count mismatch: got %d, want %d", name, len(actual.Pages), len(want.pages))
	}
	for index := range want.pages {
		got, expected := actual.Pages[index], want.pages[index]
		if got.Header.Pgno != expected.Header.Pgno || got.Header.Flags != ltx.PageHeaderFlagSize {
			return fmt.Errorf("%s: unexpected page header %d: %#v", name, index, got.Header)
		}
		if !bytes.Equal(got.Data, expected.Data) {
			return fmt.Errorf("%s: unexpected page data %d", name, index)
		}
	}
	return nil
}

func verifyDatabase(name string, data []byte, expectedSHA256 string) error {
	database := newBoundedBuffer(maxDatabaseBytes)
	decoder := ltx.NewDecoder(bytes.NewReader(data))
	if err := decoder.DecodeDatabaseTo(database); err != nil {
		return fmt.Errorf("%s: decode database with pinned Go: %w", name, err)
	}
	digest := sha256.Sum256(database.Bytes())
	actual := fmt.Sprintf("%x", digest)
	if actual != expectedSHA256 {
		return fmt.Errorf("%s: database SHA-256 mismatch: got %s, want %s", name, actual, expectedSHA256)
	}
	return nil
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

func validChainCases() []matrixCase {
	return []matrixCase{
		checkedGrow512(),
		checkedShrink4096(),
		noChecksumMaxPage(),
		checkedDelete(),
		legacyCurrent512(),
	}
}

func checkedGrow512() matrixCase {
	const caseID, pageSize = 1, 512
	page11, page12 := filled(pageSize, 0x11), filled(pageSize, 0x12)
	page21, page23 := filled(pageSize, 0x21), filled(pageSize, 0x23)
	page24, page25 := filled(pageSize, 0x24), filled(pageSize, 0x25)
	page32, page35 := filled(pageSize, 0x32), filled(pageSize, 0x35)
	firstPages := []ltx.PageSpec{page(1, page11), page(2, page12)}
	secondPages := []ltx.PageSpec{page(1, page21), page(3, page23), page(4, page24), page(5, page25)}
	thirdPages := []ltx.PageSpec{page(2, page32), page(5, page35)}
	postOne := databaseChecksum(firstPages...)
	postTwo := databaseChecksum(page(1, page21), page(2, page12), page(3, page23), page(4, page24), page(5, page25))
	finalPages := []ltx.PageSpec{page(1, page21), page(2, page32), page(3, page23), page(4, page24), page(5, page35)}
	postThree := databaseChecksum(finalPages...)
	return matrixCase{
		name: "checked-grow-512",
		inputs: []*ltx.FileSpec{
			fileSpec(sourceHeader(caseID, 1, pageSize, 2, 0, false), postOne, firstPages...),
			fileSpec(sourceHeader(caseID, 2, pageSize, 5, postOne, false), postTwo, secondPages...),
			fileSpec(sourceHeader(caseID, 3, pageSize, 5, postTwo, false), postThree, thirdPages...),
		},
		want: expected(caseID, 3, pageSize, 5, 0, postThree, finalPages),
	}
}

func checkedShrink4096() matrixCase {
	const caseID, pageSize = 2, 4096
	page41, page42 := filled(pageSize, 0x41), filled(pageSize, 0x42)
	page43, page44, page45 := filled(pageSize, 0x43), filled(pageSize, 0x44), filled(pageSize, 0x45)
	page52, page55 := filled(pageSize, 0x52), filled(pageSize, 0x55)
	page61, page63 := filled(pageSize, 0x61), filled(pageSize, 0x63)
	firstPages := []ltx.PageSpec{page(1, page41), page(2, page42), page(3, page43), page(4, page44), page(5, page45)}
	secondPages := []ltx.PageSpec{page(2, page52), page(5, page55)}
	thirdPages := []ltx.PageSpec{page(1, page61), page(3, page63)}
	postOne := databaseChecksum(firstPages...)
	postTwo := databaseChecksum(page(1, page41), page(2, page52), page(3, page43), page(4, page44), page(5, page55))
	finalPages := []ltx.PageSpec{page(1, page61), page(2, page52), page(3, page63)}
	postThree := databaseChecksum(finalPages...)
	return matrixCase{
		name: "checked-shrink-4096",
		inputs: []*ltx.FileSpec{
			fileSpec(sourceHeader(caseID, 1, pageSize, 5, 0, false), postOne, firstPages...),
			fileSpec(sourceHeader(caseID, 2, pageSize, 5, postOne, false), postTwo, secondPages...),
			fileSpec(sourceHeader(caseID, 3, pageSize, 3, postTwo, false), postThree, thirdPages...),
		},
		want: expected(caseID, 3, pageSize, 3, 0, postThree, finalPages),
	}
}

func noChecksumMaxPage() matrixCase {
	const caseID, pageSize = 3, 65_536
	page71, page72, page81 := filled(pageSize, 0x71), filled(pageSize, 0x72), filled(pageSize, 0x81)
	firstPages := []ltx.PageSpec{page(1, page71), page(2, page72)}
	secondPages := []ltx.PageSpec{page(1, page81)}
	finalPages := []ltx.PageSpec{page(1, page81)}
	return matrixCase{
		name: "no-checksum-max-page-65536",
		inputs: []*ltx.FileSpec{
			fileSpec(sourceHeader(caseID, 1, pageSize, 2, 0, true), 0, firstPages...),
			fileSpec(sourceHeader(caseID, 2, pageSize, 1, 0, true), 0, secondPages...),
		},
		want: expected(caseID, 2, pageSize, 1, ltx.HeaderFlagNoChecksum, 0, finalPages),
	}
}

func checkedDelete() matrixCase {
	const caseID, pageSize = 4, 1024
	firstPages := []ltx.PageSpec{
		page(1, filled(pageSize, 0x91)),
		page(2, filled(pageSize, 0x92)),
		page(3, filled(pageSize, 0x93)),
	}
	postOne := databaseChecksum(firstPages...)
	return matrixCase{
		name: "checked-delete-1024",
		inputs: []*ltx.FileSpec{
			fileSpec(sourceHeader(caseID, 1, pageSize, 3, 0, false), postOne, firstPages...),
			fileSpec(sourceHeader(caseID, 2, pageSize, 0, postOne, false), ltx.ChecksumFlag),
		},
		want: expected(caseID, 2, pageSize, 0, 0, ltx.ChecksumFlag, nil),
	}
}

func legacyCurrent512() matrixCase {
	const caseID, pageSize = 5, 512
	legacyPost := databaseChecksum(page(1, filled(pageSize, 0)))
	pageA1 := filled(pageSize, 0xa1)
	finalPages := []ltx.PageSpec{page(1, pageA1)}
	post := databaseChecksum(finalPages...)
	return matrixCase{
		name:   "legacy-current-512",
		legacy: true,
		inputs: []*ltx.FileSpec{
			fileSpec(sourceHeader(caseID, 2, pageSize, 1, legacyPost, false), post, finalPages...),
		},
		want: expected(caseID, 2, pageSize, 1, 0, post, finalPages),
	}
}

func expected(
	caseID, lastTXID, pageSize, commit int,
	headerFlags uint32,
	post ltx.Checksum,
	pages []ltx.PageSpec,
) expectedOutput {
	header := ltx.Header{
		Version:   ltx.Version,
		Flags:     headerFlags,
		PageSize:  uint32(pageSize),
		Commit:    uint32(commit),
		MinTXID:   1,
		MaxTXID:   ltx.TXID(lastTXID),
		Timestamp: int64(caseID*100_000 + lastTXID),
	}
	return expectedOutput{
		header:         header,
		pages:          pages,
		post:           post,
		headerFlags:    headerFlags,
		databaseSHA256: expectedDatabaseSHA(caseID),
	}
}

func expectedDatabaseSHA(caseID int) string {
	switch caseID {
	case 1:
		return "c89c89ca0c8c8a5ad990add46f40c64237cc847535b7c46a1338671f24727203"
	case 2:
		return "748180e5b2dcef3c390c2b9b26700b20df220c43455bc52f75d41e769b6f7adc"
	case 3:
		return "1f2d41b212c74e121e69ba1f71cdf254ce7b478dfb675bca590a1bb9c952354f"
	case 4:
		return "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
	case 5:
		return "a84f98fa7bc9cfbb6ee11fc4eb67c730d9648d3a32a4933b289d5cc28fc72865"
	default:
		panic("invalid matrix case")
	}
}

func sourceHeader(
	caseID, txid, pageSize, commit int,
	pre ltx.Checksum,
	noChecksum bool,
) ltx.Header {
	base := int64(caseID*1000 + txid*10)
	flags := uint32(0)
	if noChecksum {
		flags = ltx.HeaderFlagNoChecksum
		pre = 0
	}
	return ltx.Header{
		Version:          ltx.Version,
		Flags:            flags,
		PageSize:         uint32(pageSize),
		Commit:           uint32(commit),
		MinTXID:          ltx.TXID(txid),
		MaxTXID:          ltx.TXID(txid),
		Timestamp:        int64(caseID*100_000 + txid),
		PreApplyChecksum: pre,
		WALOffset:        base,
		WALSize:          base + 50,
		WALSalt1:         uint32(base + 1),
		WALSalt2:         uint32(base + 2),
		NodeID:           uint64(base + 3),
	}
}

func fileSpec(header ltx.Header, post ltx.Checksum, pages ...ltx.PageSpec) *ltx.FileSpec {
	return &ltx.FileSpec{
		Header:  header,
		Pages:   pages,
		Trailer: ltx.Trailer{PostApplyChecksum: post},
	}
}

func page(number uint32, data []byte) ltx.PageSpec {
	return ltx.PageSpec{Header: ltx.PageHeader{Pgno: number}, Data: data}
}

func filled(size int, value byte) []byte {
	return bytes.Repeat([]byte{value}, size)
}

func databaseChecksum(pages ...ltx.PageSpec) ltx.Checksum {
	checksum := ltx.ChecksumFlag
	for _, page := range pages {
		checksum = ltx.ChecksumFlag | (checksum ^ ltx.ChecksumPage(page.Header.Pgno, page.Data))
	}
	return checksum
}
