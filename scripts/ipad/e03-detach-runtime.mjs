import { spawn } from "node:child_process";
import { open, readFile, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

const root = fileURLToPath(new URL("../../", import.meta.url));
const [runID, surface] = process.argv.slice(2);
if (!/^run-[0-9]+-[0-9]+$/.test(runID ?? "") || !["api", "surfaces"].includes(surface)) {
  throw new Error("Supply a retained E03 run ID and api or surfaces");
}
const artifacts = join(root, "test-results/ipad", runID);
const environment = JSON.parse(await readFile(join(artifacts, "environment.json"), "utf8"));
if (environment.runID !== runID || environment.mode !== "e03") throw new Error("Retained isolated E03 metadata is required");
const args =
  surface === "api"
    ? ["scripts/ipad/restart-server.mjs", runID, "--allow-stopped", "--skip-build"]
    : ["scripts/ipad/e03-retain-surfaces.mjs", runID, "--web"];
const logPath = join(artifacts, `detached-${surface}-${Date.now()}.log`);
const log = await open(logPath, "a", 0o600);
let child;
try {
  child = spawn(process.execPath, args, {
    cwd: root,
    env: process.env,
    detached: true,
    stdio: ["ignore", log.fd, log.fd],
  });
  await new Promise((resolve, reject) => {
    child.once("spawn", resolve);
    child.once("error", reject);
  });
  child.unref();
} finally {
  await log.close();
}
const record = { runID, surface, supervisorPID: child.pid, logPath, detached: true, stdio: "files" };
await writeFile(join(artifacts, `detached-${surface}-runtime.json`), `${JSON.stringify(record, null, 2)}\n`, { mode: 0o600 });
console.log(JSON.stringify(record));
