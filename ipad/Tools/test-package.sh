#!/usr/bin/env bash
# Runs the BookOrbitKit tests. Extra arguments go to `swift test` (for example `--filter SignInTests`).
set -euo pipefail

PACKAGE_DIR="$(cd "$(dirname "$0")/../BookOrbitKit" && pwd)"
FLAGS=()
# Command Line Tools ship the Swift Testing macros outside the compiler's default plugin path.
PLUGINS="$(xcode-select -p)/usr/lib/swift/host/plugins/testing"
if [[ -d "$PLUGINS" ]]; then FLAGS+=(-Xswiftc -plugin-path -Xswiftc "$PLUGINS"); fi

swift test --package-path "$PACKAGE_DIR" ${FLAGS[@]+"${FLAGS[@]}"} "$@"
