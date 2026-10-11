import { spawn } from "node:child_process";
import { randomBytes } from "node:crypto";
import { createWriteStream } from "node:fs";
import { lstat, mkdir, readFile, realpath, rename, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { createRequire } from "node:module";
import { tmpdir } from "node:os";
import { fileURLToPath } from "node:url";
import { startE04Receivers } from "./e04-receivers.mjs";

const root = fileURLToPath(new URL("../../", import.meta.url));
const source = await realpath(process.argv[2] ?? "");
const recoverStopped = process.argv.includes("--recover-stopped");
if (!source.startsWith(`${root}test-results/ipad/`)) throw new Error("Retained core must belong to this checkout");
const originalHarnessPID = Number(source.match(/\/run-(\d+)-\d+$/)?.[1]);
if (!originalHarnessPID) throw new Error("Retained core must have a canonical harness run identity");
const records = [...(await readFile(join(source, "server.log"), "utf8")).matchAll(/runId=(\d+).*localhost server ready/g)];
const originalCorePID = Number(records.at(-1)?.[1]);
async function inspect(args) {
  const child = spawn("ps", args, { stdio: ["ignore", "pipe", "ignore"] });
  let text = "";
  child.stdout.on("data", (chunk) => {
    text += chunk;
    if (text.length > 256_000) child.kill("SIGTERM");
  });
  const code = await new Promise((resolve) => child.once("exit", resolve));
  if (code !== 0 || text.length > 256_000) throw new Error("Controlled core process inspection failed");
  return text;
}
const databaseName = `bookorbit_ipad_${originalHarnessPID}_e2e`;
const databaseURL = `postgres://bookorbit:bookorbit@localhost:5432/${databaseName}`;
const base = "http://127.0.0.1:16502/api/v1";
let jwt;
let token;
let contentDirectory;
async function authenticate() {
  const login = await fetch(`${base}/auth/login`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ username: "ipad-owner", password: "IpadFixture123", clientKind: "native", deviceLabel: "E04 retained core provenance" }),
  });
  if (!login.ok) throw new Error("Retained fixture owner authentication failed");
  token = (await login.json()).accessToken;
}
if (recoverStopped) {
  let listening = false;
  try {
    await fetch(`${base}/auth/login-options`, { signal: AbortSignal.timeout(1000) });
    listening = true;
  } catch {}
  if (listening) throw new Error("Stopped-core recovery requires the E04 API port to be available");
  const require = createRequire(new URL("../../server/package.json", import.meta.url));
  const { Client } = require("pg");
  const client = new Client({ connectionString: databaseURL });
  await client.connect();
  try {
    const folders = await client.query("select path from library_folders where library_id=1 and role='downloads' order by id limit 2");
    if (folders.rows.length !== 1) throw new Error("Retained fixture must have exactly one controlled content folder");
    contentDirectory = folders.rows[0].path;
  } finally {
    await client.end();
  }
  jwt = randomBytes(32).toString("hex");
} else {
  const parentPID = Number((await inspect(["-p", String(originalCorePID), "-o", "ppid="])).trim());
  if (parentPID !== originalHarnessPID) throw new Error("Retained core is not owned by the recorded harness");
  const description = await inspect(["eww", "-p", String(originalCorePID), "-o", "command="]);
  if (!description.includes("server/dist-ipad/test/ipad/harness.js")) throw new Error("Retained process is not the isolated core");
  jwt = description.match(/\bJWT_SECRET=([a-f0-9]{64})(?: |$)/)?.[1];
  if (!jwt || !description.includes(`DATABASE_URL=${databaseURL}`)) throw new Error("Retained core configuration identity does not match");
  await authenticate();
  const response = await fetch(`${base}/libraries`, { headers: { authorization: `Bearer ${token}` } });
  if (!response.ok) throw new Error("Retained fixture library provenance is unavailable");
  const libraries = await response.json();
  contentDirectory = libraries.find((library) => library.name === "Large library")?.folders?.find((folder) => folder.role === "downloads")?.path;
}
if (!contentDirectory?.startsWith(join(tmpdir(), "bookorbit-ipad-"))) throw new Error("Retained content must use its controlled temporary folder");
const information = await lstat(contentDirectory);
if (!information.isDirectory() || information.isSymbolicLink()) throw new Error("Retained content must be a regular directory");
const oldEnvironment = JSON.parse(await readFile(join(source, "receiver-environment.json"), "utf8"));
const oldHandoffs = recoverStopped
  ? await readFile(join(source, "native-state.json"), "utf8")
      .then(JSON.parse)
      .catch((error) => {
        if (error.code === "ENOENT") return {};
        throw error;
      })
  : await (await fetch(`${oldEnvironment.IPAD_E04_RECEIVER_URL}/native-handoffs`)).json();
const artifacts = join(root, "test-results/ipad", process.argv.includes("--resume-artifacts") ? "e04-resume" : "", `e04-core-refresh-${Date.now()}`);
await mkdir(artifacts, { recursive: true });
const preserveReceiverPorts = recoverStopped && process.argv.includes("--preserve-receiver-ports");
const receivers = await startE04Receivers({
  artifactDirectory: join(artifacts, "receivers"),
  ...(preserveReceiverPorts
    ? {
        httpPort: Number(new URL(oldEnvironment.IPAD_E04_RECEIVER_URL).port),
        smtpPort: Number(oldEnvironment.IPAD_E04_SMTP_PORT),
        smtpHttpPort: Number(new URL(oldEnvironment.IPAD_E04_SMTP_HTTP_URL).port),
      }
    : {}),
});
const restartDirectory = join(source, "core-restart");
await mkdir(restartDirectory, { recursive: true });
const env = {
  ...process.env,
  ...receivers.env,
  DATABASE_URL: databaseURL,
  E2E_DATABASE_URL: databaseURL,
  NODE_ENV: "test",
  JWT_SECRET: jwt,
  APP_URL: "http://localhost:16504",
  IPAD_E04_API_PORT: "16502",
  IPAD_E04_PROOF: "1",
  IPAD_E04_RESTART: "1",
  IPAD_E04_ARTIFACTS_DIR: source,
  IPAD_E04_ACTIVITY_FIXTURES: "1",
  IPAD_HARNESS_REPOSITORY_ROOT: root,
  IPAD_KOBO_SCALE_FIXTURE: "1",
  IPAD_KOBO_QUERY_OBSERVER: join(source, "kobo-query-observer.json"),
  IPAD_HARNESS_CONTENT_DIR: contentDirectory,
  NATIVE_REDIRECT_URI: "bookorbit://oauth2-callback",
  NATIVE_ADDITIONAL_REDIRECT_URIS: "bookorbit-private://oauth2-callback",
};
let core;
let interrupted = false;
process.once("SIGINT", () => {
  interrupted = true;
});
process.once("SIGTERM", () => {
  interrupted = true;
});
async function stopCore() {
  if (!core || core.exitCode !== null || core.signalCode !== null) return;
  core.kill("SIGTERM");
  await new Promise((resolve) => core.once("exit", resolve));
}
async function startCore() {
  core = spawn(
    process.execPath,
    ["--import", join(root, "scripts/ipad/kobo-query-observer.mjs"), join(root, "server/dist-ipad/test/ipad/harness.js")],
    {
      cwd: join(root, "server"),
      env,
      stdio: ["ignore", "pipe", "pipe"],
    },
  );
  const log = createWriteStream(join(artifacts, "server.log"), { flags: "a" });
  core.stdout.pipe(log, { end: false });
  core.stderr.pipe(log, { end: false });
  core.stderr.pipe(process.stderr, { end: false });
  await new Promise((resolve, reject) => {
    let tail = "";
    const timer = setTimeout(() => reject(new Error("Refreshed E04 core did not become ready")), 120_000);
    core.once("error", reject);
    core.once("exit", (code) => {
      clearTimeout(timer);
      log.end();
      reject(new Error(`Refreshed core exited ${code}`));
    });
    core.stdout.on("data", (chunk) => {
      tail = (tail + chunk).slice(-2048);
      if (tail.includes("localhost server ready")) {
        clearTimeout(timer);
        resolve();
      }
    });
  });
}
try {
  // The original fixture process deletes its temporary files on graceful exit.
  // Stop only that verified process without running cleanup; its supervisor keeps the database alive.
  if (!recoverStopped) process.kill(originalCorePID, "SIGKILL");
  await startCore();
  await authenticate();
  const fixture = JSON.parse(await readFile(join(source, "e04-fixture.json"), "utf8"));
  const providerResponse = await fetch(`${base}/email/providers/${fixture.email.providerId}`, { headers: { authorization: `Bearer ${token}` } });
  if (!providerResponse.ok) throw new Error("Existing fixture SMTP provider could not be inspected");
  const provider = await providerResponse.json();
  if (provider.host !== "127.0.0.1" || provider.port !== Number(oldEnvironment.IPAD_E04_SMTP_PORT))
    throw new Error("Only the recorded controlled SMTP fixture endpoint can be refreshed");
  const providerUpdate = await fetch(`${base}/email/providers/${provider.id}`, {
    method: "PUT",
    headers: { authorization: `Bearer ${token}`, "content-type": "application/json" },
    body: JSON.stringify({ port: receivers.smtpPort }),
  });
  if (!providerUpdate.ok) throw new Error("Controlled SMTP fixture endpoint update failed");
  fixture.email.smtpPort = receivers.smtpPort;
  await writeFile(join(source, "e04-fixture.json"), `${JSON.stringify(fixture, null, 2)}\n`);
  await writeFile(
    join(artifacts, "smtp-endpoint-transfer.json"),
    `${JSON.stringify({ providerId: provider.id, previousPort: provider.port, port: receivers.smtpPort, recipientId: fixture.email.recipientId, settingsPreserved: true })}\n`,
  );
  const usersResponse = await fetch(`${base}/users?search=ipad-reader&page=0&pageSize=10`, { headers: { authorization: `Bearer ${token}` } });
  if (!usersResponse.ok) throw new Error("Fixture reader permission inspection failed");
  const reader = (await usersResponse.json()).users.find((user) => user.username === "ipad-reader");
  if (!reader) throw new Error("Fixture reader was not found");
  const readerResponse = await fetch(`${base}/users/${reader.id}`, { headers: { authorization: `Bearer ${token}` } });
  if (!readerResponse.ok) throw new Error("Fixture reader permissions could not be read");
  const permissions = (await readerResponse.json()).permissions;
  if (!permissions.includes("hardcover_sync")) {
    const grant = await fetch(`${base}/users/${reader.id}/permissions`, {
      method: "PUT",
      headers: { authorization: `Bearer ${token}`, "content-type": "application/json" },
      body: JSON.stringify({ permissionNames: [...permissions, "hardcover_sync"] }),
    });
    if (grant.status !== 204) throw new Error("Fixture reader Hardcover permission grant failed");
  }
  await writeFile(join(source, "receiver-environment.json"), `${JSON.stringify(receivers.env, null, 2)}\n`);
  await writeFile(join(artifacts, "receiver-environment.json"), `${JSON.stringify(receivers.env, null, 2)}\n`);
  await writeFile(join(artifacts, "handoff-provenance.json"), `${JSON.stringify({ source, handoffs: oldHandoffs }, null, 2)}\n`);
  for (const caseID of ["A01", "A02", "A03", "A04", "A05"]) {
    if (!oldHandoffs[caseID]) continue;
    const receipt = await fetch(`${receivers.httpURL}/native-handoff`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(oldHandoffs[caseID]),
    });
    if (!receipt.ok) throw new Error("Literal native handoff transfer failed");
  }
  await writeFile(
    join(source, "core-refresh.json"),
    `${JSON.stringify({ artifacts, originalCorePID, corePID: core.pid, databaseName, contentDirectory, restartDirectory, recoveredStopped: recoverStopped, syntheticAuthentication: recoverStopped ? "fresh-login-required" : "preserved" }, null, 2)}\n`,
  );
  console.log(
    `[ipad.core_refresh] [end] runId=${process.pid} corePID=${core.pid} ready=true - retained database and files reopened with current compiled source`,
  );
  let completed;
  try {
    completed = JSON.parse(await readFile(join(restartDirectory, "ready.json"), "utf8")).requestId;
  } catch (error) {
    if (error.code !== "ENOENT") throw error;
  }
  while (!interrupted) {
    let request;
    try {
      request = JSON.parse(await readFile(join(restartDirectory, "request.json"), "utf8"));
    } catch (error) {
      if (error.code !== "ENOENT") throw error;
    }
    if (request && request.requestId !== completed) {
      if (!/^[a-f0-9-]{36}$/i.test(request.requestId)) throw new Error("Restart request must have a UUID identity");
      await stopCore();
      await startCore();
      completed = request.requestId;
      await writeFile(
        join(restartDirectory, "ready.tmp"),
        `${JSON.stringify({ requestId: completed, corePID: core.pid, ready: true, startedAt: new Date().toISOString() })}\n`,
      );
      await rename(join(restartDirectory, "ready.tmp"), join(restartDirectory, "ready.json"));
    }
    await new Promise((resolve) => setTimeout(resolve, 120));
  }
} finally {
  await stopCore();
  await receivers.close();
}
