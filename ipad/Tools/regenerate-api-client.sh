#!/usr/bin/env bash
# Regenerates BookOrbitAPI from the server's OpenAPI document. No database or running server needed.
# The operations to generate and their response shapes come from Tools/openapi/overlays/*.json.
set -euo pipefail

IPAD_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REPO_DIR="$(cd "$IPAD_DIR/.." && pwd)"
EXPORTER="$IPAD_DIR/Tools/openapi/export-openapi.cjs"
SPEC="$IPAD_DIR/BookOrbitKit/OpenAPI/openapi.json"
OUTPUT="$IPAD_DIR/BookOrbitKit/Sources/BookOrbitAPI/GeneratedSources"
CONFIG_DIR="$(mktemp -d)"
trap 'rm -rf "$CONFIG_DIR"' EXIT
CONFIG="$CONFIG_DIR/openapi-generator-config.yaml"

if command -v pnpm >/dev/null 2>&1; then PNPM=(pnpm); else PNPM=(npx --yes "pnpm@$(node -p "require('$REPO_DIR/package.json').packageManager.split('@')[1]")"); fi

(cd "$REPO_DIR" && "${PNPM[@]}" install --frozen-lockfile && "${PNPM[@]}" --filter server build)
node "$EXPORTER" "$REPO_DIR/server" > "$SPEC"
# Formatted like the pre-commit hook would, so regenerating twice produces no diff.
(cd "$REPO_DIR" && "${PNPM[@]}" exec prettier --write "$SPEC" >/dev/null)

{
  printf 'generate:\n  - types\n  - client\naccessModifier: public\nnamingStrategy: idiomatic\nfilter:\n  operations:\n'
  node "$EXPORTER" --operations | sed 's/^/    - /'
} > "$CONFIG"

swift run --package-path "$IPAD_DIR/Tools/OpenAPIGenerator" -c release swift-openapi-generator generate \
  --config "$CONFIG" --output-directory "$OUTPUT" "$SPEC"
