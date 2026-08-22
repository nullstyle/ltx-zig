package main

import (
	"bytes"
	"os"
	"path/filepath"
	"testing"
)

func TestBoundedBufferRejectsOverflow(t *testing.T) {
	buffer := newBoundedBuffer(4)
	if _, err := buffer.Write([]byte{1, 2, 3, 4}); err != nil {
		t.Fatalf("write exact capacity: %v", err)
	}
	if _, err := buffer.Write([]byte{5}); err == nil {
		t.Fatal("expected bounded buffer overflow")
	}
	if got := buffer.Bytes(); !bytes.Equal(got, []byte{1, 2, 3, 4}) {
		t.Fatalf("buffer changed after rejected write: %v", got)
	}
}

func TestReadBoundedFileRejectsOversize(t *testing.T) {
	path := filepath.Join(t.TempDir(), "oversize.ltx")
	if err := os.WriteFile(path, []byte{1, 2, 3, 4, 5}, 0o600); err != nil {
		t.Fatalf("write test file: %v", err)
	}
	if _, err := readBoundedFile(path, 4); err == nil {
		t.Fatal("expected oversized file rejection")
	}
}
