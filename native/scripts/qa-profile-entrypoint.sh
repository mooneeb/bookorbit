#!/usr/bin/env bash
set -euo pipefail
install -d -o postgres -g postgres /tmp/bookorbit-qa-pg /tmp/bookorbit-qa-socket
runuser -u postgres -- /usr/lib/postgresql/18/bin/initdb -D /tmp/bookorbit-qa-pg --username=qa --auth=trust >/tmp/bookorbit-qa-init.log
runuser -u postgres -- /usr/lib/postgresql/18/bin/pg_ctl -D /tmp/bookorbit-qa-pg -o '-h 127.0.0.1 -k /tmp/bookorbit-qa-socket -c shared_buffers=256MB' -l /tmp/bookorbit-qa-postgres.log start
trap 'runuser -u postgres -- /usr/lib/postgresql/18/bin/pg_ctl -D /tmp/bookorbit-qa-pg stop -m fast >/dev/null 2>&1 || true' EXIT
runuser -u postgres -- /usr/lib/postgresql/18/bin/createdb -h 127.0.0.1 -U qa bookorbit_qa
export E2E_DATABASE_URL=postgres://qa@127.0.0.1:5432/bookorbit_qa
export JWT_SECRET=isolated-native-qa-signing-key-not-a-production-secret
export NODE_ENV=test
export NATIVE_QA_BIND=0.0.0.0
export NATIVE_QA_LINK_PROBE=1
export NATIVE_QA_OUTPUT=/output
DATABASE_URL="$E2E_DATABASE_URL" pnpm --config.verify-deps-before-run=false --dir server db:migrate
node - <<'JS'
const fs = require('node:fs');
const os = require('node:os');
const {execFileSync} = require('node:child_process');
fs.writeFileSync('/output/profile.json', JSON.stringify({sourceCommit:process.env.QA_SOURCE_COMMIT,node:process.version,postgres:execFileSync('/usr/lib/postgresql/18/bin/postgres',['--version'],{encoding:'utf8'}).trim(),platform:process.platform,architecture:process.arch,kernel:os.release(),memoryTotal:os.totalmem(),cpuMax:fs.readFileSync('/sys/fs/cgroup/cpu.max','utf8').trim(),memoryMax:fs.readFileSync('/sys/fs/cgroup/memory.max','utf8').trim()},null,2));
JS
NATIVE_QA_SESSION=1 pnpm --config.verify-deps-before-run=false --dir server exec vitest run --config vitest.config.e2e.ts test/native-qa-session.e2e-spec.ts
