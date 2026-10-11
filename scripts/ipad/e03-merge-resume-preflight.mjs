import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { isAbsolute } from "node:path";

export async function loadMergeResumeFixture(env = process.env, read = readFile) {
  for (const key of ["IPAD_MERGE_FIXTURE", "IPAD_MERGE_RESUME_PROBE"]) {
    assert.ok(
      env[key],
      `Retained merge continuation requires ${key}: prepare a dedicated completed merge with a live keeper; ordinary A05 deletes its keeper`,
    );
  }
  const fixture = JSON.parse(await read(env.IPAD_MERGE_FIXTURE, "utf8"));
  const probe = JSON.parse(await read(env.IPAD_MERGE_RESUME_PROBE, "utf8"));
  for (const key of ["targetBookId", "sourceBookId", "sourceFileId", "targetFileId", "libraryId", "libraryFolderId"]) {
    assert.ok(Number.isSafeInteger(fixture[key]) && fixture[key] > 0, `Retained merge continuation requires a positive ${key} in IPAD_MERGE_FIXTURE`);
  }
  assert.equal(probe.keeperBookId, fixture.targetBookId, "Retained merge probe must identify the dedicated fixture's keeper");
  assert.ok(
    typeof probe.newPath === "string" && isAbsolute(probe.newPath),
    "Retained merge probe requires an absolute newPath to prepared new content",
  );
  return { fixture, probe };
}

export async function assertLiveMergeResumeKeeper(fixture, getBook) {
  const keeper = await getBook(fixture.targetBookId);
  assert.equal(
    keeper.status,
    200,
    `Retained merge continuation requires live keeper ${fixture.targetBookId} before any scan or deletion; prepare an independent retained fixture instead of reusing ordinary A05`,
  );
  const book = await keeper.json();
  assert.equal(book.libraryId, fixture.libraryId, "Retained keeper must belong to the dedicated fixture library");
  assert.deepEqual(
    book.files.map((file) => file.id).sort((a, b) => a - b),
    [fixture.sourceFileId, fixture.targetFileId].sort((a, b) => a - b),
    "Retained keeper must already own both merged fixture files before mutations",
  );
  const source = await getBook(fixture.sourceBookId);
  assert.equal(source.status, 404, "Retained merge continuation requires the source book to have already been merged");
}
