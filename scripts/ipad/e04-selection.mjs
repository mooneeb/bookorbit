import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";

const manifestURL = new URL("../../docs/ipad/e04-acceptance-manifest.json", import.meta.url);

export async function readingSharingSelection(caseName) {
  assert.ok(!caseName || /^A0[1-5]$/.test(caseName), "E04 --case must be A01 through A05");
  const manifest = JSON.parse(await readFile(manifestURL, "utf8"));
  const caseIDs = caseName ? [caseName] : Object.keys(manifest.cases);
  const cases = caseIDs.map((id) => ({ id, ...manifest.cases[id] }));
  return {
    ticket: manifest.ticket,
    manifest: fileURLToPath(manifestURL),
    caseIDs,
    cases,
    httpFiles: [...new Set(cases.flatMap((entry) => entry.httpFiles))],
    native: [...new Set(cases.flatMap((entry) => entry.native))],
    browser: [...new Set(cases.flatMap((entry) => entry.browser))],
  };
}

export function assertReadingSharingCoverage(selection, surfaces) {
  for (const entry of selection.cases) {
    for (const surface of surfaces) {
      const field = surface === "http" ? "httpFiles" : surface;
      assert.ok(entry[field]?.length > 0, `IPAD-E04-${entry.id} has no implemented ${surface} entry in the acceptance manifest`);
    }
  }
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const caseName = process.argv.find((argument) => argument.startsWith("--case="))?.slice(7);
  console.log(JSON.stringify(await readingSharingSelection(caseName), null, 2));
}
