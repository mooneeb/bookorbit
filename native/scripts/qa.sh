#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
qa_container="bookorbit57-qa-$$"
trap 'docker rm -f "$qa_container" >/dev/null 2>&1 || true' EXIT
docker run -d --rm --name "$qa_container" --cpus=4 --memory=8g \
  -e POSTGRES_USER=qa -e POSTGRES_PASSWORD=qa-local-only -e POSTGRES_DB=bookorbit_qa \
  -p 127.0.0.1::5432 pgvector/pgvector:pg18 >/dev/null
for attempt in {1..60}; do
  if docker exec "$qa_container" pg_isready -U qa >/dev/null 2>&1; then break; fi
  sleep 1
done
qa_port="$(docker port "$qa_container" 5432/tcp | cut -d: -f2)"
export E2E_DATABASE_URL="postgres://qa:qa-local-only@127.0.0.1:$qa_port/bookorbit_qa"
export JWT_SECRET=isolated-native-qa-signing-key-not-a-production-secret
export NODE_ENV=test
DATABASE_URL="$E2E_DATABASE_URL" pnpm --dir server db:migrate
pnpm --filter @bookorbit/types build
pnpm --filter @bookorbit/plugin-api build
xcodegen generate --spec native/project.yml
NATIVE_QA=1 pnpm --dir server exec vitest run --config vitest.config.e2e.ts test/native-offline.e2e-spec.ts
