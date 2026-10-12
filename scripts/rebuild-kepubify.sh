#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
go_bin="${GO_BIN:-go}"
source_commit=9546034bc023891af5ce30709de6ae2dcf264628

if [[ "$("$go_bin" version)" != "go version go1.27.2 "* ]]; then
  echo 'Use Go 1.27.2 (set GO_BIN to its executable).' >&2
  exit 1
fi

build_dir="$(mktemp -d)"
trap 'rm -rf "$build_dir"' EXIT
git clone --quiet https://github.com/pgaskin/kepubify.git "$build_dir/source"
git -C "$build_dir/source" checkout --quiet "$source_commit"
cd "$build_dir/source"
export GOTOOLCHAIN=local CGO_ENABLED=0 GOMAXPROCS=2 GOMEMLIMIT=1GiB
cp "$repo_root/scripts/kepubify/go.mod" "$repo_root/scripts/kepubify/go.sum" .

while read -r target_os target_arch target_name target_arm; do
  GOOS="$target_os" GOARCH="$target_arch" GOARM="$target_arm" \
    "$go_bin" build -mod=readonly -p 2 -trimpath -ldflags='-s -w' \
    -o "$build_dir/$target_name" ./cmd/kepubify
  "$go_bin" version -m "$build_dir/$target_name"
done <<'TARGETS'
darwin amd64 kepubify-darwin-64bit 6
darwin arm64 kepubify-darwin-arm64 6
linux 386 kepubify-linux-32bit 6
linux amd64 kepubify-linux-64bit 6
linux arm kepubify-linux-arm 7
linux arm64 kepubify-linux-arm64 6
TARGETS

for binary in "$build_dir"/kepubify-*; do
  install -m 755 "$binary" "$repo_root/server/bin/kepubify/$(basename "$binary")"
done
