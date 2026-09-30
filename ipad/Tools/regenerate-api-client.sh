#!/usr/bin/env bash
# Regenerates BookOrbitAPI from the server's OpenAPI document. No database or running server needed.
set -euo pipefail

IPAD_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REPO_DIR="$(cd "$IPAD_DIR/.." && pwd)"
SPEC="$IPAD_DIR/BookOrbitKit/OpenAPI/openapi.json"
CONFIG="$IPAD_DIR/BookOrbitKit/OpenAPI/openapi-generator-config.yaml"
OUTPUT="$IPAD_DIR/BookOrbitKit/Sources/BookOrbitAPI/GeneratedSources"

if command -v pnpm >/dev/null 2>&1; then PNPM=(pnpm); else PNPM=(npx --yes "pnpm@$(node -p "require('$REPO_DIR/package.json').packageManager.split('@')[1]")"); fi

(cd "$REPO_DIR" && "${PNPM[@]}" install --frozen-lockfile && "${PNPM[@]}" --filter server build)
node "$IPAD_DIR/Tools/openapi/export-openapi.cjs" "$REPO_DIR/server" > "$SPEC"
# Formatted like the pre-commit hook would, so regenerating twice produces no diff.
(cd "$REPO_DIR" && "${PNPM[@]}" exec prettier --write "$SPEC" >/dev/null)

swift run --package-path "$IPAD_DIR/Tools/OpenAPIGenerator" -c release swift-openapi-generator generate \
  --config "$CONFIG" --output-directory "$OUTPUT" "$SPEC"
