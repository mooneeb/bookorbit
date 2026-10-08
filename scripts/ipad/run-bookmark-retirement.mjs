import { spawn } from "node:child_process";
import { randomBytes } from "node:crypto";
import { createWriteStream } from "node:fs";
import { mkdir, writeFile } from "node:fs/promises";
import { createRequire } from "node:module";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

const root = fileURLToPath(new URL("../../", import.meta.url));
const require = createRequire(new URL("../../server/package.json", import.meta.url));
const { Client } = require("pg");
const runID = `bookmark-retirement-${process.pid}-${Date.now()}`;
const databaseName = `bookorbit_bookmark_retirement_${process.pid}${Date.now()}_e2e`;
const databaseURL = `postgres://bookorbit:bookorbit@localhost:5432/${databaseName}`;
const artifacts = join(root, "test-results/ipad", runID);
await mkdir(artifacts, { recursive: true });
await writeFile(
  join(artifacts, "environment.json"),
  `${JSON.stringify({ runID, databaseName, test: "IPAD-E02-A05-bookmark-retirement", retainedFixtureTouched: false }, null, 2)}\n`,
);
const log = createWriteStream(join(artifacts, "retirement-http.log"));
const env = {
  ...process.env,
  DATABASE_URL: databaseURL,
  E2E_DATABASE_URL: databaseURL,
  JWT_SECRET: randomBytes(32).toString("hex"),
  NODE_ENV: "test",
  pnpm_config_verify_deps_before_run: "false",
};
let child;
let interrupted = false;
function stop() {
  interrupted = true;
  if (child?.pid) process.kill(-child.pid, "SIGTERM");
}
process.once("SIGINT", stop);
process.once("SIGTERM", stop);
async function command(args) {
  if (interrupted) throw new Error("Retirement HTTP run interrupted");
  child = spawn("pnpm", args, { cwd: root, env, detached: true, stdio: ["ignore", "pipe", "pipe"] });
  child.stdout.pipe(log, { end: false });
  child.stderr.pipe(log, { end: false });
  child.stdout.pipe(process.stdout, { end: false });
  child.stderr.pipe(process.stderr, { end: false });
  await new Promise((resolve, reject) => {
    child.once("error", reject);
    child.once("close", (code) => {
      child = undefined;
      if (code === 0 && !interrupted) resolve();
      else reject(new Error(`Retirement HTTP command exited (${code})`));
    });
  });
}
try {
  await command(["--filter", "server", "e2e:db:prepare"]);
  await command(["--filter", "server", "db:migrate"]);
  await command(["--filter", "server", "exec", "vitest", "run", "--config", "vitest.config.bookmark-retirement.ts"]);
  console.log(`[ipad.bookmark_retirement] [end] runId=${runID} - public protocol checks completed`);
} finally {
  const admin = new Client({ connectionString: "postgres://bookorbit:bookorbit@localhost:5432/postgres" });
  await admin.connect();
  try {
    await admin.query(`DROP DATABASE IF EXISTS "${databaseName}" WITH (FORCE)`);
  } finally {
    await admin.end();
    log.end();
  }
}
