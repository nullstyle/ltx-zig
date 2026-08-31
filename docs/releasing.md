# Releasing

This checklist prepares and publishes an `ltx-zig` release. A local `act` run
is a Linux rehearsal only; the hosted Linux and macOS jobs remain the release
authority.

## Prepare the version

1. Start from a clean `main` worktree whose hosted CI run is green.
2. Set `.version` in `build.zig.zon`, add the matching version section to
   `CHANGELOG.md`, and update versioned command examples in `README.md` and this
   checklist. During release-candidate work, keep the new changelog heading in
   the form `## [X.Y.Z] - TBD` (for example, `## [0.4.0] - TBD`).
3. On the final release commit, replace `TBD` with the real release date in
   `YYYY-MM-DD` form. Do not create the tag while the heading is still pending.
4. Review `LICENSE`, `LICENSE.pierrec-lz4`, and
   `LICENSE.celld-litestream-apache-2.0`; all notices must remain in the
   package.
5. Validate the intended tag, including its leading `v`:

   ```sh
   mise exec -- zig build release-check -Drelease-tag=v0.3.0
   ```

Without `-Drelease-tag`, the release checker accepts the matching `TBD` heading
while release-candidate work continues. With a release tag, it requires a real,
valid `YYYY-MM-DD` date and rejects a pending heading. It also rejects malformed
or mismatched package/tag versions, missing public modules or required package
paths, stale versioned command examples, and changed license notice digests.

## Run the local gates

Install the pinned developer and oracle toolchains, then run the direct gates:

```sh
mise install
mise exec -- zig build fmt-check
mise exec -- zig build check-fixtures
mise exec -- zig build check-legacy-fixtures
mise exec -- zig build test
mise exec -- zig build test -Doptimize=ReleaseSafe
mise exec -- zig build sqlite-integration
mise exec -- zig build sqlite-integration -Doptimize=ReleaseSafe
mise exec -- zig build capture-integration
mise exec -- zig build capture-integration -Doptimize=ReleaseSafe
mise run s3-integration
mise exec -- zig build consumer-compile
mise exec -- zig build consumer-smoke -Doptimize=ReleaseSafe
mise exec -- zig build resource-check -Doptimize=ReleaseSafe
mise exec -- zig build bench-compile -Dbench-optimize=ReleaseSafe
mise exec -- zig build benchmark-smoke -Dbench-optimize=ReleaseSafe
mise exec -- zig build example-round-trip -Doptimize=ReleaseSafe
mise exec -- zig build example-apply-snapshot -Doptimize=ReleaseSafe
mise exec -- zig build example-sqlite-store -Doptimize=ReleaseSafe
mise exec -- zig build example-replicate-once -Doptimize=ReleaseSafe
mise exec -- zig build source-archive-smoke -Doptimize=ReleaseSafe
mise exec -- zig build fuzz --fuzz=10K -Doptimize=ReleaseSafe --seed 0
GOTOOLCHAIN=local mise exec -- zig build interop -Doptimize=ReleaseSafe
mise exec -- zig build litestream-interop -Doptimize=ReleaseSafe \
  -Dlitestream=/absolute/path/to/litestream
```

`consumer-compile` and `consumer-smoke` exercise the current external
path-dependency wiring. They are regression gates for the coordinated
consumer, not a source-compatibility promise. `source-archive-smoke` asks the
pinned Zig executable to create its canonical local `zig fetch` tarball,
extracts it away from the checkout, and
runs the archived consumer plus all four examples with isolated local and
global caches. It therefore checks package-path completeness without a cached
or live-source fallback; the replication example makes the host SQLite
development library a prerequisite. The gate does not replace fetching the
final remote tag.
`benchmark-smoke` verifies all 17 deterministic benchmark cases, including
encoded bytes and digests, decoded images, compacted semantics, and
callback/event/page counts. Neither it nor any other CI gate compares elapsed
time or throughput.

Use the official Litestream v0.5.16 archive for the host and verify its
SHA-256 against the values recorded in [`upstream.md`](upstream.md) before the
`litestream-interop` command. The harness also rejects every reported version
other than exactly `0.5.16`. It uses only a temporary local file replica and
does not contact a configured remote replica.

For capture-throughput or restore-path changes, also run the bounded scale
qualification required by the engineering rules and update the measured
numbers in [`replication.md`](replication.md) if they moved materially:

```sh
mise exec -- zig build scale-check -Dscale-mb=64
```

With Docker running, parse and then execute the pinned Ubuntu CI rehearsal:

```sh
mise run ci-local -- --dryrun
mise run ci-local
```

The first full run downloads the digest-pinned Ubuntu runner image and requires
outbound access for GitHub Actions, Ubuntu packages, mise tools, Go modules,
and the checksum-pinned Litestream release archive.
Run it only from a trusted, reviewed worktree. The host Docker daemon is not
mounted into the job container. The current public workflow needs no secrets.
If GitHub rate limits a run, use `mise run ci-local -- -s GITHUB_TOKEN` and
enter a least-privilege token at the secure prompt. Workflow code receives any
supplied token, so never use this fallback on an untrusted branch or put a token
in `.actrc` or another committed file. The repository ignores the default
`.secrets` file as a final guardrail.

`act` intentionally selects only the `ubuntu-24.04` test matrix entry. Its
container is a close approximation, not a hosted-runner replica, and it cannot
qualify `macos-15`. The container replays the deterministic fuzz corpora while
hosted native Linux performs the instrumented 10K search. Push the release
commit and require every hosted test and portability job to succeed before
tagging.

## Tag and publish

1. Confirm `git status --short` is empty, the `0.3.0` changelog heading contains
   the real release date rather than `TBD`, and the hosted commit is green.
2. Create an annotated `v${package_version}` tag on that exact commit.
3. Push the tag and require the tag-triggered release check and full CI matrix
   to succeed.
4. Create the GitHub release from the matching changelog section and attach no
   generated binaries unless their contents and both license notices have been
   reviewed.
5. Fetch the tagged archive from a fresh consumer and run its build before
   announcing the release.
