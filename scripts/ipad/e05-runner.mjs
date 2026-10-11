import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";

const suites = {
  A01: ["e05-profile-http.test.mjs"],
  A02: ["e05-session-http.test.mjs", "e05-account-admin-http.test.mjs"],
  A03: ["e05-settings-http.test.mjs", "e05-account-admin-http.test.mjs"],
  A04: ["e05-settings-http.test.mjs", "e05-account-admin-http.test.mjs"],
};

export function e05Suites(caseID, { inventoryOnly = false } = {}) {
  if (caseID && !/^A0[1-6]$/.test(caseID)) throw new Error("E05 case must be A01 through A06");
  if (caseID && !suites[caseID]) {
    if (inventoryOnly) return [];
    throw new Error(`E05 ${caseID} HTTP coverage not implemented; no tests were executed`);
  }
  return [...new Set(caseID ? suites[caseID] : Object.values(suites).flat())].map((file) => `scripts/ipad/${file}`);
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const caseID = process.argv.find((value) => value.startsWith("--case="))?.slice(7);
  const inventoryOnly = process.argv.includes("--list");
  const files = e05Suites(caseID, { inventoryOnly });
  if (inventoryOnly)
    console.log(
      JSON.stringify(
        {
          caseID: caseID ?? "all",
          suites: files,
          cases: Object.fromEntries(
            ["A01", "A02", "A03", "A04", "A05", "A06"].map((id) => [id, suites[id] ? "implemented" : "coverage-not-implemented"]),
          ),
        },
        null,
        2,
      ),
    );
  else
    for (const file of files)
      await new Promise((resolve, reject) => {
        const child = spawn(process.execPath, ["--test", "--test-concurrency=1", file], { stdio: "inherit", env: process.env });
        child.once("error", reject);
        child.once("close", (code, signal) => (code === 0 ? resolve() : reject(new Error(`${file} failed (${code ?? signal})`))));
      });
}
