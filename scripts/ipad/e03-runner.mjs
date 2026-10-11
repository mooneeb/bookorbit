import { spawn } from "node:child_process";
import { readdir } from "node:fs/promises";
import { fileURLToPath } from "node:url";

const groups = {
  A01: /(?:upload|scan|dock-recovery)/,
  A02: /(?:requests|request-admin|request-lifecycle)/,
  A03: /migration/,
  A04: /bulk/,
  A05: /(?:entit|maintenance|duplicate-merge|merge-preservation|rename)/,
};

const retainedContinuation = "e03-duplicate-merge-rescan-resume-http.test.mjs";

export async function e03Suites(caseID, { retainedMergeContinuation = false } = {}) {
  if (caseID && !groups[caseID]) throw new Error("E03 case must be A01 through A05");
  if (retainedMergeContinuation) {
    if (caseID && caseID !== "A05") throw new Error("Retained merge continuation belongs to A05");
    return [`scripts/ipad/${retainedContinuation}`];
  }
  const files = (await readdir(fileURLToPath(new URL("./", import.meta.url))))
    .filter((file) => /^e03-.*-http\.test\.mjs$/.test(file))
    .filter((file) => file !== retainedContinuation)
    .filter((file) => !caseID || groups[caseID].test(file))
    .sort();
  if (!files.length) throw new Error(`No implemented E03 HTTP suite exists for ${caseID ?? "all cases"}`);
  return files.map((file) => `scripts/ipad/${file}`);
}

async function main() {
  const caseID = process.argv.find((value) => value.startsWith("--case="))?.slice(7);
  const files = await e03Suites(caseID, { retainedMergeContinuation: process.argv.includes("--retained-merge-continuation") });
  if (process.argv.includes("--list")) {
    console.log(JSON.stringify({ caseID: caseID ?? "all", suites: files }, null, 2));
    return;
  }
  for (const file of files) {
    await new Promise((resolve, reject) => {
      const child = spawn(process.execPath, ["--test", "--test-concurrency=1", file], { stdio: "inherit", env: process.env });
      const stop = () => child.kill("SIGTERM");
      process.once("SIGINT", stop);
      process.once("SIGTERM", stop);
      child.once("error", reject);
      child.once("close", (code, signal) => {
        process.removeListener("SIGINT", stop);
        process.removeListener("SIGTERM", stop);
        if (code === 0) resolve();
        else reject(new Error(`${file} failed (${code ?? signal})`));
      });
    });
  }
}

if (process.argv[1] === fileURLToPath(import.meta.url)) await main();
