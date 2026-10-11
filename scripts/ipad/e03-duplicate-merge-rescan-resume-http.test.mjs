import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { mkdir, readFile, utimes, writeFile } from "node:fs/promises";
import { createRequire } from "node:module";
import { dirname, isAbsolute, join, relative } from "node:path";
import { test } from "node:test";
import { assertLiveMergeResumeKeeper, loadMergeResumeFixture } from "./e03-merge-resume-preflight.mjs";

const require = createRequire(new URL("../../server/package.json", import.meta.url));
const { PDFDocument } = require("pdf-lib");
const base = process.env.IPAD_API_BASE ?? "http://localhost:16482/api/v1";

async function request(path, token, body, method = body ? "POST" : "GET") {
  return fetch(`${base}/${path}`, {
    method,
    headers: { ...(token ? { Authorization: `Bearer ${token}` } : {}), ...(body ? { "Content-Type": "application/json" } : {}) },
    body: body ? JSON.stringify(body) : undefined,
  });
}

async function json(path, token, body, method) {
  const response = await request(path, token, body, method);
  assert.ok(response.ok, `${path}: ${response.status} ${await response.clone().text()}`);
  const content = await response.text();
  return content ? JSON.parse(content) : undefined;
}

async function delivered(fileId, token) {
  const response = await request(`books/files/${fileId}/serve`, token);
  assert.equal(response.status, 200);
  return Buffer.from(await response.arrayBuffer());
}

function contains(root, path) {
  const child = relative(root, path);
  return child === "" || (!isAbsolute(child) && child !== ".." && !child.startsWith("../"));
}

async function scanLibrary(libraryId, token, requireCandidates = true) {
  const started = await json(`scanner/libraries/${libraryId}/scan`, token, {});
  for (let attempt = 0; attempt < 120; attempt++) {
    const { progress } = await json(`scanner/libraries/${libraryId}/scan-status`, token);
    if (progress?.jobId === started.jobId && progress.status !== "running") {
      assert.equal(progress.status, "completed", progress.errorMessage);
      if (requireCandidates) assert.ok(progress.total > 0, "New content must produce scan candidates");
      return progress;
    }
    await new Promise((resolve) => setTimeout(resolve, 250));
  }
  assert.fail("Rescan did not finish within 30 seconds");
}

async function findExactPath(library, path, token) {
  const page = await json("books/query", token, {
    filter: { type: "group", join: "AND", rules: [{ type: "rule", field: "library", operator: "includesAny", value: [library.name] }] },
    sort: [{ field: "title", dir: "asc" }],
    pagination: { page: 0, size: 50 },
  });
  assert.ok(page.total <= 50, "This continuation requires the bounded dedicated fixture library");
  const matches = [];
  for (let offset = 0; offset < page.items.length; offset += 4) {
    const books = await Promise.all(page.items.slice(offset, offset + 4).map((item) => json(`books/${item.id}`, token)));
    for (const book of books) {
      const file = book.files.find((item) => item.absolutePath === path);
      if (file) matches.push({ book, file });
    }
  }
  assert.equal(matches.length, 1, "New source-folder content is catalogued independently at its exact path");
  return matches[0];
}

async function readerState(fixture, token) {
  const [keeper, progress, sessions, bookmarks, annotations] = await Promise.all([
    json(`books/${fixture.targetBookId}`, token),
    json(`books/files/${fixture.sourceFileId}/progress`, token),
    json(`books/${fixture.targetBookId}/sessions`, token),
    json(`books/${fixture.targetBookId}/bookmarks`, token),
    json(`annotations/native/delta?bookId=${fixture.targetBookId}&cursor=0&limit=100`, token),
  ]);
  assert.ok(annotations.items.length < 100, "The dedicated fixture annotation snapshot must be complete");
  return {
    primaryFileId: keeper.primaryFileId,
    fileIds: keeper.files.map((file) => file.id).sort((a, b) => a - b),
    personalNote: keeper.personalNote,
    progress,
    sessions,
    bookmarks,
    annotations: annotations.items,
  };
}

test("IPAD-E03-A05-rescan-resume: configured roots retain the completed merge, catalogue new bytes and release a deleted keeper", async () => {
  const { fixture, probe } = await loadMergeResumeFixture();
  const session = await json("auth/login", undefined, {
    username: "ipad-owner",
    password: "IpadFixture123",
    clientKind: "native",
    deviceLabel: "E03 merge rescan continuation",
  });
  const token = session.accessToken;
  const scans = [];
  const artifactDirectory = process.env.IPAD_ARTIFACT_DIR ?? dirname(process.env.IPAD_MERGE_RESUME_PROBE);
  try {
    await assertLiveMergeResumeKeeper(fixture, (bookId) => request(`books/${bookId}`, token));
    const library = await json(`libraries/${fixture.libraryId}`, token);
    const root = library.folders.find((folder) => folder.id === fixture.libraryFolderId && contains(folder.path, probe.newPath));
    assert.ok(root, "The containing configured root must match this merge receipt's libraryFolderId");
    assert.equal((await request(`books/${fixture.sourceBookId}`, token)).status, 404);
    const before = await readerState(fixture, token);
    assert.deepEqual(
      before.fileIds,
      [fixture.sourceFileId, fixture.targetFileId].sort((a, b) => a - b),
    );
    assert.equal(before.personalNote, "Private duplicate merge note retained");
    assert.equal(before.progress.percentage, 42);
    assert.ok(before.annotations.some((item) => item.kind === "pdf_ink" && item.jumpFileId === fixture.sourceFileId));
    assert.ok(before.annotations.some((item) => item.deletedAt));
    assert.ok(before.annotations.some((item) => item.note === "Private passage note survives rescans" && item.jumpFileId === fixture.sourceFileId));
    const sourceBytes = await delivered(fixture.sourceFileId, token);
    const targetBytes = await delivered(fixture.targetFileId, token);
    assert.deepEqual(sourceBytes, await readFile(join(artifactDirectory, "qa5-merge-artifacts", `merged-source-${fixture.sourceFileId}.pdf`)));
    assert.deepEqual(targetBytes, await readFile(join(artifactDirectory, "qa5-merge-artifacts", `merged-target-${fixture.targetFileId}.pdf`)));
    const newBytes = await readFile(probe.newPath);
    const sourceDirectory = dirname(probe.newPath);
    const completedRepeatJobId = process.env.IPAD_MERGE_RESUME_COMPLETED_REPEAT_SCAN
      ? Number(process.env.IPAD_MERGE_RESUME_COMPLETED_REPEAT_SCAN)
      : undefined;
    let history;

    if (process.env.IPAD_MERGE_RESUME_COMPLETED_SCAN) {
      const completedJobId = Number(process.env.IPAD_MERGE_RESUME_COMPLETED_SCAN);
      assert.ok(Number.isSafeInteger(completedJobId) && completedJobId > 0);
      history = await json(`scanner/libraries/${fixture.libraryId}/scan-history?limit=5`, token);
      assert.equal(history[0].id, completedRepeatJobId ?? completedJobId, "Resume from the latest already completed scan only");
      const first = history.find((item) => item.id === completedJobId);
      assert.equal(first?.status, "completed");
      scans.push({ ...first, alreadyCompleted: true });
    } else {
      assert.equal(completedRepeatJobId, undefined);
      scans.push(await scanLibrary(fixture.libraryId, token));
    }
    let unrelated;
    if (completedRepeatJobId !== undefined) {
      assert.ok(Number.isSafeInteger(completedRepeatJobId) && completedRepeatJobId > 0);
      const repeat = history.find((item) => item.id === completedRepeatJobId);
      assert.equal(repeat?.status, "completed");
      scans.push({ ...repeat, alreadyCompleted: true });
    } else {
      unrelated = await findExactPath(library, probe.newPath, token);
      assert.notEqual(unrelated.book.id, fixture.targetBookId);
      assert.notEqual(unrelated.book.id, fixture.sourceBookId);
      assert.deepEqual(await delivered(unrelated.file.id, token), newBytes);
      assert.deepEqual(await readerState(fixture, token), before);
      assert.deepEqual(await delivered(fixture.sourceFileId, token), sourceBytes);
      assert.deepEqual(await delivered(fixture.targetFileId, token), targetBytes);
      assert.equal((await request(`books/${fixture.sourceBookId}`, token)).status, 404);

      const changedAt = new Date();
      await utimes(sourceDirectory, changedAt, changedAt);
      scans.push(await scanLibrary(fixture.libraryId, token, false));
    }
    const repeated = await findExactPath(library, probe.newPath, token);
    if (unrelated) {
      assert.equal(repeated.book.id, unrelated.book.id);
      assert.equal(repeated.file.id, unrelated.file.id);
    }
    assert.notEqual(repeated.book.id, fixture.targetBookId);
    assert.notEqual(repeated.book.id, fixture.sourceBookId);
    assert.deepEqual(await delivered(repeated.file.id, token), newBytes);
    if (completedRepeatJobId !== undefined) {
      await mkdir(artifactDirectory, { recursive: true });
      const checkpointPath = join(artifactDirectory, "merge-rescan-state-checkpoint.json");
      const checkpoint = { completedScans: scans, before, unrelatedBookId: repeated.book.id, unrelatedFileId: repeated.file.id };
      await writeFile(checkpointPath, JSON.stringify(checkpoint, null, 2));
      const focusedScan = await scanLibrary(fixture.libraryId, token, false);
      scans.push(focusedScan);
      const after = await readerState(fixture, token);
      assert.deepEqual(after, before);
      const afterFocusedScan = await findExactPath(library, probe.newPath, token);
      assert.equal(afterFocusedScan.book.id, repeated.book.id);
      assert.equal(afterFocusedScan.file.id, repeated.file.id);
      await writeFile(checkpointPath, JSON.stringify({ ...checkpoint, focusedScan, after }, null, 2));
    }
    assert.deepEqual(await readerState(fixture, token), before);
    assert.deepEqual(await delivered(fixture.sourceFileId, token), sourceBytes);
    assert.deepEqual(await delivered(fixture.targetFileId, token), targetBytes);
    assert.equal((await request(`books/${fixture.sourceBookId}`, token)).status, 404);

    const deletion = await request("books", token, { bookIds: [fixture.targetBookId] }, "DELETE");
    assert.equal(deletion.status, 204, await deletion.text());
    assert.equal((await request(`books/${fixture.targetBookId}`, token)).status, 404);
    const replacement = await PDFDocument.create();
    replacement.setTitle(`Content after keeper deletion ${randomUUID()}`);
    replacement.addPage([600, 800]).drawText("A deleted keeper cannot own newly scanned content", { x: 40, y: 700 });
    const replacementBytes = Buffer.from(await replacement.save());
    const replacementPath = join(sourceDirectory, "replacement.pdf");
    await mkdir(sourceDirectory, { recursive: true });
    await writeFile(replacementPath, replacementBytes);
    scans.push(await scanLibrary(fixture.libraryId, token));
    const afterDeletion = await findExactPath(library, replacementPath, token);
    assert.notEqual(afterDeletion.book.id, fixture.targetBookId);
    assert.notEqual(afterDeletion.book.id, fixture.sourceBookId);
    assert.deepEqual(await delivered(afterDeletion.file.id, token), replacementBytes);
    assert.equal((await request(`books/${fixture.targetBookId}`, token)).status, 404);
    assert.equal((await request(`books/${fixture.sourceBookId}`, token)).status, 404);
    await mkdir(artifactDirectory, { recursive: true });
    await writeFile(
      join(artifactDirectory, "merge-rescan-continuation-proof.json"),
      JSON.stringify(
        {
          root,
          sourceBookId: fixture.sourceBookId,
          keeperBookId: fixture.targetBookId,
          unrelatedBookId: repeated.book.id,
          unrelatedFileId: repeated.file.id,
          replacementBookId: afterDeletion.book.id,
          replacementFileId: afterDeletion.file.id,
          scans,
          preservedState: before,
        },
        null,
        2,
      ),
    );
  } finally {
    await json("auth/logout", undefined, { refreshToken: session.refreshToken });
  }
});
