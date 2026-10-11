# Bundled kepubify provenance

BookOrbit bundles kepubify from upstream commit
[`9546034bc023891af5ce30709de6ae2dcf264628`](https://github.com/pgaskin/kepubify/tree/9546034bc023891af5ce30709de6ae2dcf264628).
The executable reports `v4-dev`, matching the previously bundled converter.
The pinned `go.mod` and `go.sum` preserve its linked dependencies, including
`golang.org/x/sync v0.22.0` and `golang.org/x/text v0.41.0`.
No converter source changes are applied.

kepubify is distributed under the MIT license. The upstream copyright and
permission notice ships with the binaries in
[`server/bin/kepubify/LICENSE`](../../server/bin/kepubify/LICENSE), which is included
in the container image.

The rebuilt main module metadata is
`v4.0.5-0.20220522015003-9546034bc023+dirty`, whereas the previous binaries
reported `v4.0.0-20220522015003-9546034bc023+dirty`. The current upstream tag
history changes this derived pseudo-version; the exact source revision and
linked dependency versions remain the same. Go 1.27.2 also adds
`httpservecontentmaxranges=1` to the embedded `DefaultGODEBUG` settings.

[`build-provenance.json`](build-provenance.json) records the toolchain archive
checksum, dependency lock checksums, architecture metadata, and conversion
comparison results for the six shipped binaries. Verify their committed checksums
from the repository root:

```sh
(cd server/bin/kepubify && shasum -a 256 -c ../../../scripts/kepubify/SHA256SUMS)
```

Rebuild all six existing platform artifacts with the official
[Go 1.27.2 toolchain](https://go.dev/dl/#go1.27.2):

```sh
GO_BIN=/path/to/go1.27.2/bin/go ./scripts/rebuild-kepubify.sh
```

The script checks the toolchain version, checks out the pinned upstream commit,
copies the dependency locks, and builds with `CGO_ENABLED=0`, `-trimpath`, and
`-ldflags='-s -w'`. It preserves Linux ARM's `GOARM=7`, Linux 386/amd64/arm64,
and macOS amd64/arm64. It builds in a temporary directory before replacing the
six executables and prints their actual Go build metadata.

Go 1.27.2 fixes the runtime vulnerabilities
[GO-2026-6609](https://pkg.go.dev/vuln/GO-2026-6609),
[GO-2026-6611](https://pkg.go.dev/vuln/GO-2026-6611), and
[GO-2026-6607](https://pkg.go.dev/vuln/GO-2026-6607) reported against the previous
Go 1.27.0 binaries. Keep the required container security scan enabled when
updating these artifacts. These findings concern bundled runtime code; remote
application exploitability through the local-file converter is not established.

Fixed-layout fullscreen support remains in BookOrbit's Kobo sync service, which
announces pre-paginated books as `EPUB3FL`. Conversion must continue preserving
the OPF `rendition:layout` metadata and inserting Kobo progress spans.
