package main

import (
	"fmt"
	"os"

	"github.com/superfly/ltx"
)

func main() {
	if len(os.Args) != 2 {
		fmt.Fprintln(os.Stderr, "usage: upstream_verify <ltx-file>")
		os.Exit(2)
	}

	file, err := os.Open(os.Args[1])
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	if got, want := info.Size(), int64(168); got != want {
		fmt.Fprintf(os.Stderr, "unexpected physical byte count: got %d, want %d\n", got, want)
		os.Exit(1)
	}

	decoder := ltx.NewDecoder(file)
	if err := decoder.Verify(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	if got, want := decoder.N(), int64(648); got != want {
		fmt.Fprintf(os.Stderr, "unexpected Go logical byte count: got %d, want %d\n", got, want)
		os.Exit(1)
	}
	if got, want := decoder.PageN(), 1; got != want {
		fmt.Fprintf(os.Stderr, "unexpected page count: got %d, want %d\n", got, want)
		os.Exit(1)
	}
	if got, want := uint64(decoder.Trailer().FileChecksum), uint64(0xeb5121d56d33a656); got != want {
		fmt.Fprintf(os.Stderr, "unexpected file checksum: got %016x, want %016x\n", got, want)
		os.Exit(1)
	}
	fmt.Println("pinned Go LTX verified Zig output")
}
