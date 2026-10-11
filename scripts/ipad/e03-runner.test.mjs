import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { readFile } from "node:fs/promises";
import { test } from "node:test";
import { promisify } from "node:util";
import { e03Suites } from "./e03-runner.mjs";
import { assertLiveMergeResumeKeeper, loadMergeResumeFixture } from "./e03-merge-resume-preflight.mjs";

const continuation = "scripts/ipad/e03-duplicate-merge-rescan-resume-http.test.mjs";

test("ordinary all/A05 discovery preserves standard suites and excludes retained continuation", async () => {
  const all = await e03Suites();
  const a05 = await e03Suites("A05");
  assert.ok(!all.includes(continuation));
  assert.ok(!a05.includes(continuation));
  for (const name of ["duplicate-merge", "duplicate-merge-preservation", "maintenance", "rename"]) {
    const file = `scripts/ipad/e03-${name}-http.test.mjs`;
    assert.ok(all.includes(file), file);
    assert.ok(a05.includes(file), file);
  }
  assert.deepEqual(await e03Suites("A05", { retainedMergeContinuation: true }), [continuation]);
});

test("fresh ordinary A05 registry requires only normal prepared environment", async () => {
  const env = { ...process.env, IPAD_MERGE_FIXTURE: "/prepared/ordinary-merge.json" };
  for (const key of Object.keys(env)) if (key.startsWith("IPAD_MERGE_RESUME_")) delete env[key];
  const { stdout } = await promisify(execFile)(process.execPath, ["scripts/ipad/e03-runner.mjs", "--case=A05", "--list"], { env });
  const { suites } = JSON.parse(stdout);
  assert.ok(suites.length > 0);
  assert.ok(!suites.includes(continuation));
  for (const file of suites) {
    assert.doesNotMatch(await readFile(file, "utf8"), /IPAD_MERGE_RESUME_|e03-merge-resume-preflight/);
  }
});

test("explicit continuation rejects missing probe or dead keeper before mutations and accepts dedicated fixture", async () => {
  let reads = 0;
  await assert.rejects(
    loadMergeResumeFixture({ IPAD_MERGE_FIXTURE: "/fixture.json" }, async () => {
      reads++;
    }),
    /requires IPAD_MERGE_RESUME_PROBE/,
  );
  assert.equal(reads, 0);
  const fixture = { targetBookId: 108, sourceBookId: 107, sourceFileId: 207, targetFileId: 208, libraryId: 1, libraryFolderId: 2 };
  const probe = { keeperBookId: 108, newPath: "/dedicated/new.pdf" };
  const prepared = await loadMergeResumeFixture({ IPAD_MERGE_FIXTURE: "/fixture.json", IPAD_MERGE_RESUME_PROBE: "/probe.json" }, async (path) =>
    JSON.stringify(path === "/fixture.json" ? fixture : probe),
  );
  assert.deepEqual(prepared, { fixture, probe });
  const deadCalls = [];
  await assert.rejects(
    assertLiveMergeResumeKeeper(fixture, async (id) => {
      deadCalls.push(id);
      return { status: 404 };
    }),
    /requires live keeper 108 before any scan or deletion/,
  );
  assert.deepEqual(deadCalls, [108]);
  const liveCalls = [];
  await assertLiveMergeResumeKeeper(fixture, async (id) => {
    liveCalls.push(id);
    return id === fixture.targetBookId ? { status: 200, json: async () => ({ libraryId: 1, files: [{ id: 208 }, { id: 207 }] }) } : { status: 404 };
  });
  assert.deepEqual(liveCalls, [108, 107]);
});
