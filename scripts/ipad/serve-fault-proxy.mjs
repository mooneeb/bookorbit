import { execFile } from "node:child_process";
import { open, readFile, rename } from "node:fs/promises";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";
import { sanitizeLogValue } from "../../server/src/common/utils/log-sanitize.utils.ts";
import { startFaultProxy } from "./fault-proxy.mjs";

const execute = promisify(execFile);
const root = fileURLToPath(new URL("../../", import.meta.url));
const runID = process.argv[2];
const match = runID?.match(/^run-([0-9]+)-[0-9]+$/);
if (!match || process.argv.slice(3).some((argument) => argument !== "--replace-outer")) {
  throw new Error("Supply the retained isolated run ID and optional --replace-outer");
}
const outerPID = Number(match[1]);
const artifacts = join(root, "test-results/ipad", runID);
const environment = JSON.parse(await readFile(join(artifacts, "environment.json"), "utf8"));
if (environment.runID !== runID || environment.apiURL !== "http://localhost:16482/api/v1") {
  throw new Error("Retained metadata does not match this isolated API");
}
async function listener(port) {
  let stdout;
  try {
    ({ stdout } = await execute("lsof", [`-tiTCP:${port}`, "-sTCP:LISTEN"], { maxBuffer: 4096 }));
  } catch (error) {
    if (error.code === 1 && !error.stdout?.trim()) return undefined;
    throw error;
  }
  const pids = [...new Set(stdout.trim().split(/\s+/).filter(Boolean))];
  if (pids.length !== 1 || !/^[1-9][0-9]*$/.test(pids[0])) throw new Error(`Port ${port} has ambiguous ownership`);
  return Number(pids[0]);
}
async function command(pid) {
  return (await execute("ps", ["-p", String(pid), "-o", "command="], { maxBuffer: 4096 })).stdout;
}
const apiPID = await listener(16482);
if (!apiPID || !(await command(apiPID)).includes("server/dist-ipad/test/ipad/harness.js")) {
  throw new Error("The retained isolated API must be running before proxy refresh");
}
const webPID = await listener(16484);
const proxyPID = await listener(16485);
if (proxyPID) {
  if (!process.argv.includes("--replace-outer") || proxyPID !== outerPID) {
    throw new Error("Proxy port is occupied; only the named retained outer process may be replaced explicitly");
  }
  const outerCommand = await command(outerPID);
  if (!outerCommand.includes("scripts/ipad/run-harness.mjs") || !outerCommand.includes("--annotations") || !outerCommand.includes("--serve")) {
    throw new Error("The proxy owner is not the retained annotation harness");
  }
  // Normal outer shutdown drops the fixture database, so this handoff must suppress its cleanup.
  process.kill(outerPID, "SIGKILL");
  for (let attempt = 0; attempt < 20 && (await listener(16485)); attempt++) {
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  if (await listener(16485)) throw new Error("The old proxy listener did not close");
}
const stopProxy = await startFaultProxy();
const metadataPath = join(artifacts, "proxy-runtime.json");
async function record(state) {
  const temporaryPath = `${metadataPath}.${process.pid}.tmp`;
  const file = await open(temporaryPath, "w", 0o600);
  try {
    await file.writeFile(
      `${JSON.stringify({ runID, pid: process.pid, state, apiPID, webPID, replacedOuterPID: proxyPID ?? null, database: `bookorbit_ipad_${outerPID}_e2e`, cleanupOwner: "root: stop API and web, then drop this isolated database" }, null, 2)}\n`,
    );
    await file.sync();
  } finally {
    await file.close();
  }
  await rename(temporaryPath, metadataPath);
}
await record("running");
console.log(
  `[ipad.fault_proxy] [end] runId=${runID} proxyPid=${process.pid} apiPid=${apiPID} - refreshed transport controls ready; retained fixture cleanup belongs to root`,
);
let stopping = false;
async function stop() {
  if (stopping) return;
  stopping = true;
  try {
    await stopProxy();
    await record("stopped");
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    console.error(`[ipad.fault_proxy] [fail] runId=${runID} error="${sanitizeLogValue(message)}" - proxy shutdown failed`);
    process.exitCode = 1;
  }
}
process.once("SIGINT", () => void stop());
process.once("SIGTERM", () => void stop());
