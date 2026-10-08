import { execFile, spawn } from "node:child_process";
import { randomBytes } from "node:crypto";
import { createWriteStream } from "node:fs";
import { open, readFile, rename, stat, unlink } from "node:fs/promises";
import { createRequire } from "node:module";
import { dirname, join } from "node:path";
import { tmpdir } from "node:os";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";

const execute = promisify(execFile);
const root = fileURLToPath(new URL("../../", import.meta.url));
const runID = process.argv[2];
const allowStopped = process.argv.includes("--allow-stopped");
if (process.argv.slice(3).some((argument) => argument !== "--allow-stopped")) throw new Error("Unknown recovery argument");
const match = runID?.match(/^run-([0-9]+)-[0-9]+$/);
if (!match) throw new Error("Supply the existing retained isolated harness run ID");
const runPID = Number(match[1]);
const databaseName = `bookorbit_ipad_${runPID}_e2e`;
const databaseURL = `postgres://bookorbit:bookorbit@localhost:5432/${databaseName}`;
const artifacts = join(root, "test-results/ipad", runID);
const environment = JSON.parse(await readFile(join(artifacts, "environment.json"), "utf8"));
if (environment.runID !== runID || environment.apiURL !== "http://localhost:16482/api/v1")
  throw new Error("Retained run metadata does not match the isolated API");
const require = createRequire(new URL("../../server/package.json", import.meta.url));
const { Client } = require("pg");
const client = new Client({ connectionString: databaseURL });
await client.connect();
let folder;
try {
  const result = await client.query("select absolute_path from book_files where id = $1", [1]);
  if (result.rowCount !== 1) throw new Error("The retained source fixture is absent");
  folder = dirname(result.rows[0].absolute_path);
} finally {
  await client.end();
}
if (!folder.startsWith(join(tmpdir(), "bookorbit-ipad-"))) throw new Error("Only controlled temporary fixtures can be restarted");
if (!(await stat(folder)).isDirectory()) throw new Error("The controlled source folder is absent");
async function listenerPID() {
  let listeners;
  try {
    ({ stdout: listeners } = await execute("lsof", ["-tiTCP:16482", "-sTCP:LISTEN"], { maxBuffer: 4096 }));
  } catch (error) {
    if (error.code !== 1 || error.stdout?.trim()) throw error;
    return undefined;
  }
  const pids = [...new Set(listeners.trim().split(/\s+/).filter(Boolean))];
  if (pids.length !== 1 || !/^[1-9][0-9]*$/.test(pids[0])) throw new Error("Exactly one retained API listener is required");
  const pid = Number(pids[0]);
  const { stdout: command } = await execute("ps", ["-p", String(pid), "-o", "command="], { maxBuffer: 4096 });
  if (!command.includes("server/dist-ipad/test/ipad/harness.js")) throw new Error("API listener is not the isolated iPad harness");
  return pid;
}
const lockPath = join(artifacts, "api-restart.lock");
const lock = await open(lockPath, "wx", 0o600);
await lock.writeFile(`${process.pid}\n`);
await lock.sync();
let oldPID;
let jwtSecret;
try {
  oldPID = await listenerPID();
  if (!oldPID && !allowStopped) throw new Error("No retained API listener; use --allow-stopped only to recover this isolated fixture");
  console.log(
    `[ipad.harness_restart] [start] runId=${runID} runtimePid=${oldPID ?? "stopped"} - rebuilding while preserving isolated persistence and content`,
  );
  await execute("pnpm", ["--filter", "server", "exec", "tsc", "-p", "tsconfig.ipad.json"], { cwd: root, env: process.env, maxBuffer: 1024 * 1024 });
  if ((await listenerPID()) !== oldPID) throw new Error("API listener changed during compilation; no process was replaced");
  const secretPath = join(artifacts, "runtime-jwt-secret");
  try {
    jwtSecret = (await readFile(secretPath, "utf8")).trim();
  } catch (error) {
    if (error.code !== "ENOENT") throw error;
    jwtSecret = randomBytes(32).toString("hex");
    const secret = await open(secretPath, "wx", 0o600);
    try {
      await secret.writeFile(`${jwtSecret}\n`);
      await secret.sync();
    } finally {
      await secret.close();
    }
  }
  if (!/^[a-f0-9]{64}$/.test(jwtSecret)) throw new Error("Retained isolated signing configuration is invalid");
  if (oldPID) process.kill(oldPID, "SIGKILL");
} catch (error) {
  await lock.close();
  await unlink(lockPath);
  throw error;
}
const logPath = join(artifacts, `server-restart-${Date.now()}.log`);
const log = createWriteStream(logPath);
const child = spawn(process.execPath, ["server/dist-ipad/test/ipad/harness.js"], {
  cwd: root,
  env: {
    ...process.env,
    DATABASE_URL: databaseURL,
    E2E_DATABASE_URL: databaseURL,
    NODE_ENV: "test",
    APP_URL: "http://localhost:16484",
    IPAD_TEST_RUN: runID,
    IPAD_ANNOTATIONS_PROOF: "1",
    IPAD_REUSE_FIXTURE: "1",
    IPAD_HARNESS_CONTENT_DIR: folder,
    JWT_SECRET: jwtSecret,
    SETUP_BOOTSTRAP_TOKEN: "",
    NATIVE_REDIRECT_URI: "bookorbit://oauth2-callback",
    NATIVE_ADDITIONAL_REDIRECT_URIS: "bookorbit-private://oauth2-callback",
    IPAD_COVER_FIXTURE_DIR: join(artifacts, "cover-fixture"),
  },
  stdio: ["ignore", "pipe", "pipe"],
});
child.stdout.pipe(log, { end: false });
child.stderr.pipe(log, { end: false });
child.stdout.pipe(process.stdout, { end: false });
child.stderr.pipe(process.stderr, { end: false });
const metadataPath = join(artifacts, "restarted-runtime.json");
async function recordRuntime(state, exitCode) {
  const temporaryPath = `${metadataPath}.${process.pid}.tmp`;
  const metadata = await open(temporaryPath, "w", 0o600);
  try {
    await metadata.writeFile(
      `${JSON.stringify({ runID, pid: child.pid, supervisorPID: process.pid, logPath, state, exitCode, previousPID: oldPID ?? null, recoveredStopped: !oldPID, auth: "retained per-run signing key; fresh login on first recovery from earlier runtime" }, null, 2)}\n`,
    );
    await metadata.sync();
  } finally {
    await metadata.close();
  }
  await rename(temporaryPath, metadataPath);
  const directory = await open(artifacts, "r");
  try {
    await directory.sync();
  } finally {
    await directory.close();
  }
}
await recordRuntime("starting");
await lock.close();
await unlink(lockPath);
process.once("SIGINT", () => child.kill("SIGTERM"));
process.once("SIGTERM", () => child.kill("SIGTERM"));
const exitCode = await new Promise((resolve, reject) => {
  child.once("error", reject);
  child.once("close", (code) => resolve(code));
});
log.end();
await recordRuntime("stopped", exitCode);
if (exitCode !== 0) throw new Error(`Restarted isolated server exited (${exitCode})`);
