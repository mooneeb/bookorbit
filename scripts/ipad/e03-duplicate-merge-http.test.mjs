import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { createRequire } from "node:module";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { test } from "node:test";

const require = createRequire(new URL("../../server/package.json", import.meta.url));
const { PDFDocument, PDFDict, PDFName, PDFNumber } = require("pdf-lib");
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
async function login(username) {
  return json("auth/login", undefined, { username, password: "IpadFixture123", clientKind: "native", deviceLabel: "E03 duplicate merge HTTP" });
}
async function scanLibrary(libraryId, token) {
  const response = await request(`scanner/libraries/${libraryId}/scan`, token, {});
  assert.equal(response.status, 202, await response.clone().text());
  const started = await response.json();
  for (let attempt = 0; attempt < 120; attempt++) {
    const { progress } = await json(`scanner/libraries/${libraryId}/scan-status`, token);
    if (progress?.jobId === started.jobId && progress.status !== "running") {
      assert.equal(progress.status, "completed", progress.errorMessage);
      return;
    }
    await new Promise((resolve) => setTimeout(resolve, 250));
  }
  assert.fail("Rescan did not finish within 30 seconds");
}

async function delivered(fileId, token) {
  const response = await request(`books/files/${fileId}/serve`, token);
  assert.equal(response.status, 200);
  return Buffer.from(await response.arrayBuffer());
}
async function deliveredAudio(bookId, token) {
  const manifest = await json(`audiobooks/${bookId}/manifest`, token);
  assert.equal(manifest.assets.length, 1);
  const response = await request(`audiobooks/${bookId}/assets/${manifest.assets[0].assetId}/content`, token);
  assert.equal(response.status, 200);
  return Buffer.from(await response.arrayBuffer());
}
async function operation(token, item) {
  return (await json("annotations/native/operations", token, { deviceId: "E03 merge preservation", operations: [item] })).results[0];
}
async function pdfInkIds(bytes) {
  const pdf = await PDFDocument.load(bytes);
  return pdf.getPages().flatMap((page) =>
    (page.node.Annots()?.asArray() ?? []).flatMap((reference) => {
      const entry = pdf.context.lookup(reference);
      if (!(entry instanceof PDFDict)) return [];
      const id = entry.lookupMaybe(PDFName.of("BookOrbitAnnotationId"), PDFNumber)?.asNumber();
      return id == null ? [] : [id];
    }),
  );
}

test("IPAD-E03-A05-merge-preview: selected duplicate pair has a guarded preservation preview", async () => {
  const fixture = JSON.parse(await readFile(process.env.IPAD_MERGE_FIXTURE, "utf8"));
  const owner = await login("ipad-owner");
  const restricted = await login("ipad-restricted");
  const pair = { sourceBookId: fixture.sourceBookId, targetBookId: fixture.targetBookId };
  try {
    const preview = await json("book-duplicates/merge/preview", owner.accessToken, pair);
    assert.equal(preview.canApply, true);
    assert.deepEqual(preview.blockers, []);
    assert.equal(preview.filesPreserved, 2);
    assert.match(preview.previewToken, /^[a-f0-9]{64}$/);
    assert.equal((await request("book-duplicates/merge/preview", restricted.accessToken, pair)).status, 403);
    assert.equal((await request("book-duplicates/merge/preview", undefined, pair)).status, 401);
  } finally {
    await json("auth/logout", undefined, { refreshToken: owner.refreshToken });
    await json("auth/logout", undefined, { refreshToken: restricted.refreshToken });
  }
});

test("IPAD-E03-A05-merge-apply: conflicts and stale previews refuse safely; files, ink, reader state and tombstones survive retry", async (t) => {
  const fixture = JSON.parse(await readFile(process.env.IPAD_MERGE_FIXTURE, "utf8"));
  const owner = await login("ipad-owner");
  const restricted = await login("ipad-restricted");
  const token = owner.accessToken;
  const pair = { sourceBookId: fixture.sourceBookId, targetBookId: fixture.targetBookId };
  const note = "Private duplicate merge note retained";
  try {
    await json(`books/${pair.sourceBookId}/personal-note`, token, { note }, "PATCH");
    await json(`books/${pair.targetBookId}/personal-note`, token, { note: "Conflicting private note" }, "PATCH");
    const blocked = await json("book-duplicates/merge/preview", token, pair);
    assert.equal(blocked.canApply, false);
    assert.ok(blocked.blockers.some((value) => value.includes("user book notes")));
    assert.equal((await request("book-duplicates/merge/apply", token, { ...pair, previewToken: blocked.previewToken })).status, 409);
    assert.equal((await request(`books/${pair.sourceBookId}`, token)).status, 200);
    await json(`books/${pair.targetBookId}/personal-note`, token, { note }, "PATCH");

    await json(`books/files/${fixture.sourceFileId}/progress`, token, { source: "text", percentage: 42, pageNumber: 1 });
    const endedAt = new Date(Date.now() - 300000).toISOString();
    const startedAt = new Date(Date.parse(endedAt) - 120000).toISOString();
    assert.equal(
      (
        await request(`books/files/${fixture.sourceFileId}/sessions`, token, {
          sessionId: randomUUID(),
          startedAt,
          endedAt,
          durationSeconds: 120,
          progressDelta: 12,
          endProgress: 42,
          sessionType: "read",
          source: "ios",
        })
      ).status,
      204,
    );
    const sessions = await json(`books/${pair.sourceBookId}/sessions`, token);
    const bookmark = await json(`books/${pair.sourceBookId}/bookmarks/fixed-page`, token, {
      clientId: randomUUID(),
      fileId: fixture.sourceFileId,
      pageNumber: 1,
      title: "Duplicate merge reading place",
    });
    const privatePassage = await operation(token, {
      operationId: randomUUID(),
      clientId: randomUUID(),
      bookId: pair.sourceBookId,
      baseVersion: 0,
      action: "create",
      payload: { kind: "text_note", cfi: "epubcfi(/6/2!/4/2:1)", text: "A retained passage", note: "Private passage note survives rescans" },
    });
    assert.equal(privatePassage.status, "applied");
    const sourcePassages = await json(`books/${pair.sourceBookId}/annotations?page=1&pageSize=100`, token);
    const sourcePassageBefore = sourcePassages.items.find((item) => item.id === privatePassage.annotation.id);
    assert.equal(sourcePassageBefore.jumpFileId, fixture.sourceFileId);
    const legacyBookmark = await json(`books/${pair.sourceBookId}/bookmarks`, token, {
      clientId: randomUUID(),
      cfi: "epubcfi(/6/2!/4/2:1)",
      title: "Legacy passage bookmark retains its source file",
    });
    const keeperBookmark = await json(`books/${pair.targetBookId}/bookmarks`, token, {
      clientId: randomUUID(),
      cfi: "epubcfi(/6/4!/4/2:1)",
      title: "Keeper passage bookmark retains its unchanged main file",
    });
    await t.test("legacy source passage bookmarks refuse a primary file change", async () => {
      try {
        const bookmarkGuard = await json("book-duplicates/merge/preview", token, pair);
        assert.equal(bookmarkGuard.canApply, false, "A passage bookmark cannot silently move to a different primary file");
        assert.ok(bookmarkGuard.blockers.some((value) => value.toLowerCase().includes("passage bookmarks")));
        assert.equal((await request("book-duplicates/merge/apply", token, { ...pair, previewToken: bookmarkGuard.previewToken })).status, 409);
        assert.equal((await request(`books/${pair.sourceBookId}`, token)).status, 200);
        assert.equal((await request(`books/${pair.targetBookId}`, token)).status, 200);
        const guardedBookmarks = await json(`books/${pair.sourceBookId}/bookmarks`, token);
        assert.equal(guardedBookmarks.find((item) => item.id === legacyBookmark.id).cfi, legacyBookmark.cfi);
      } finally {
        assert.equal((await request(`books/${pair.sourceBookId}/bookmarks/${legacyBookmark.id}`, token, undefined, "DELETE")).status, 204);
      }
    });
    const deletedClientId = randomUUID();
    const created = await operation(token, {
      operationId: randomUUID(),
      clientId: deletedClientId,
      bookId: pair.sourceBookId,
      baseVersion: 0,
      action: "create",
      payload: {
        kind: "text_note",
        bookFileId: fixture.sourceFileId,
        pdf: { page: 0, rect: { x: 0.1, y: 0.1, width: 0.2, height: 0.1 }, rects: [] },
        text: "Deleted passage",
        note: "Committed deletion remains authoritative",
      },
    });
    assert.equal(created.status, "applied");
    const removed = await operation(token, {
      operationId: randomUUID(),
      clientId: deletedClientId,
      annotationId: created.annotation.id,
      bookId: pair.sourceBookId,
      baseVersion: created.annotation.version,
      action: "delete",
    });
    assert.ok(removed.annotation.deletedAt);
    const source = await json(`annotations/native/files/${fixture.sourceFileId}/source?bookId=${pair.sourceBookId}&page=0`, token);
    const ink = await operation(token, {
      operationId: randomUUID(),
      clientId: randomUUID(),
      bookId: pair.sourceBookId,
      baseVersion: 0,
      action: "create",
      payload: {
        kind: "pdf_ink",
        bookFileId: fixture.sourceFileId,
        sourceRevision: source.sourceRevision,
        pageFingerprint: source.pageFingerprint,
        pdf: { page: 0, rect: { x: 80, y: 600, width: 100, height: 8 }, rects: [] },
        drawing: {
          format: "bookorbit-ink-v1",
          strokes: [
            {
              id: "merge-source-ink",
              color: "#ff0000",
              width: 8,
              points: [
                { x: 80, y: 600 },
                { x: 180, y: 600 },
              ],
            },
          ],
        },
      },
    });
    assert.equal(ink.status, "applied");
    assert.equal(ink.publication.status, "published");
    const sourceBytes = await delivered(fixture.sourceFileId, token);
    const targetBytes = await delivered(fixture.targetFileId, token);
    assert.ok((await pdfInkIds(sourceBytes)).includes(ink.annotation.id), "Delivered source contains published PDF ink");
    const progress = await json(`books/files/${fixture.sourceFileId}/progress`, token);
    const stale = await json("book-duplicates/merge/preview", token, pair);
    await json(`books/${pair.targetBookId}/personal-note`, token, { note: `${note} changed after preview` }, "PATCH");
    assert.equal((await request("book-duplicates/merge/apply", token, { ...pair, previewToken: stale.previewToken })).status, 409);
    assert.deepEqual(await delivered(fixture.sourceFileId, token), sourceBytes);
    await json(`books/${pair.targetBookId}/personal-note`, token, { note }, "PATCH");
    const preview = await json("book-duplicates/merge/preview", token, pair);
    assert.equal(preview.canApply, true, preview.blockers.join("; "));
    const body = { ...pair, previewToken: preview.previewToken };
    assert.equal((await request("book-duplicates/merge/apply", restricted.accessToken, body)).status, 403);
    assert.equal((await request("book-duplicates/merge/apply", undefined, body)).status, 401);
    assert.equal((await request("book-duplicates/merge/apply", token, pair)).status, 400);
    assert.equal((await request("book-duplicates/merge/apply", token, { ...body, unexpected: true })).status, 400);
    const result = await json("book-duplicates/merge/apply", token, body);
    assert.deepEqual(result, { ...pair, filesPreserved: 2, alreadyApplied: false });
    assert.deepEqual(await json("book-duplicates/merge/apply", token, body), { ...result, alreadyApplied: true });
    assert.equal((await request(`books/${pair.sourceBookId}`, token)).status, 404);
    const target = await json(`books/${pair.targetBookId}`, token);
    assert.deepEqual(
      target.files.map((file) => file.id).sort((a, b) => a - b),
      [fixture.sourceFileId, fixture.targetFileId].sort((a, b) => a - b),
    );
    assert.equal(target.personalNote, note);
    const keeperBookmarks = await json(`books/${pair.targetBookId}/bookmarks`, token);
    assert.deepEqual(
      keeperBookmarks.find((item) => item.id === keeperBookmark.id),
      keeperBookmark,
      "A passage bookmark is preserved when its main file remains unchanged",
    );
    const mergedPassages = await json(`books/${pair.targetBookId}/annotations?page=1&pageSize=100`, token);
    await t.test("legacy source passage anchors retain their original jump file", () => {
      assert.equal(
        mergedPassages.items.find((item) => item.id === privatePassage.annotation.id).jumpFileId,
        sourcePassageBefore.jumpFileId,
        "Legacy source passage anchors retain their original jump file",
      );
    });
    assert.deepEqual(await json(`books/files/${fixture.sourceFileId}/progress`, token), progress);
    const afterSessions = await json(`books/${pair.targetBookId}/sessions`, token);
    assert.deepEqual(afterSessions, sessions);
    const bookmarks = await json(`books/${pair.targetBookId}/bookmarks/page?fileId=${fixture.sourceFileId}&limit=100`, token);
    assert.ok(bookmarks.items.some((item) => item.id === bookmark.id && item.clientId === bookmark.clientId));
    const delta = await json(`annotations/native/delta?bookId=${pair.targetBookId}&cursor=0&limit=100`, token);
    assert.ok(delta.items.some((item) => item.id === ink.annotation.id && item.jumpFileId === fixture.sourceFileId));
    assert.ok(delta.items.some((item) => item.id === removed.annotation.id && item.deletedAt && item.version === removed.annotation.version));
    const offline = await operation(token, {
      operationId: randomUUID(),
      clientId: deletedClientId,
      annotationId: removed.annotation.id,
      bookId: pair.targetBookId,
      baseVersion: created.annotation.version,
      action: "update",
      payload: { note: "Offline stale edit must stay in recovery" },
    });
    assert.equal(offline.status, "recovery");
    assert.deepEqual(await delivered(fixture.sourceFileId, token), sourceBytes, "Merge retains the exact current source PDF including visible ink");
    assert.deepEqual(await delivered(fixture.targetFileId, token), targetBytes, "Merge preserves both files independently");
    const passageBefore = delta.items.find((item) => item.id === privatePassage.annotation.id);
    assert.ok(passageBefore);
    const primaryFileId = target.primaryFileId;
    const sourceDirectory = dirname(target.files.find((file) => file.id === fixture.sourceFileId).absolutePath);
    assert.equal((await request(`scanner/libraries/${fixture.libraryId}/scan`, restricted.accessToken, {})).status, 403);
    for (let rescan = 0; rescan < 2; rescan++) {
      await scanLibrary(fixture.libraryId, token);
      assert.equal((await request(`books/${pair.sourceBookId}`, token)).status, 404);
      const keeper = await json(`books/${pair.targetBookId}`, token);
      assert.equal(keeper.primaryFileId, primaryFileId);
      assert.deepEqual(
        keeper.files.map((file) => file.id).sort((a, b) => a - b),
        [fixture.sourceFileId, fixture.targetFileId].sort((a, b) => a - b),
      );
      assert.equal(keeper.personalNote, note);
      assert.deepEqual(await delivered(fixture.sourceFileId, token), sourceBytes);
      assert.deepEqual(await delivered(fixture.targetFileId, token), targetBytes);
      assert.deepEqual(await json(`books/files/${fixture.sourceFileId}/progress`, token), progress);
      const rescannedDelta = await json(`annotations/native/delta?bookId=${pair.targetBookId}&cursor=0&limit=100`, token);
      assert.deepEqual(
        rescannedDelta.items.find((item) => item.id === privatePassage.annotation.id),
        passageBefore,
      );
    }
    const newTitle = `Unrelated source folder content ${randomUUID()}`;
    const newPdf = await PDFDocument.create();
    newPdf.setTitle(newTitle);
    newPdf.addPage([600, 800]).drawText("New content must have its own book", { x: 40, y: 700 });
    const newBytes = Buffer.from(await newPdf.save());
    const newPath = join(sourceDirectory, "unrelated-content.pdf");
    await writeFile(newPath, newBytes);
    await scanLibrary(fixture.libraryId, token);
    const withNewContent = await json(`books/${pair.targetBookId}`, token);
    assert.deepEqual(
      withNewContent.files.map((file) => file.id).sort((a, b) => a - b),
      [fixture.sourceFileId, fixture.targetFileId].sort((a, b) => a - b),
    );
    const unrelated = await json("books/query", token, { q: newTitle, sort: [{ field: "title", dir: "asc" }], pagination: { page: 1, size: 10 } });
    assert.equal(unrelated.total, 1, "New source-folder content is catalogued independently");
    assert.notEqual(unrelated.items[0].id, pair.targetBookId);
    const unrelatedBook = await json(`books/${unrelated.items[0].id}`, token);
    const unrelatedFile = unrelatedBook.files.find((file) => file.absolutePath === newPath);
    assert.ok(unrelatedFile);
    assert.deepEqual(await delivered(unrelatedFile.id, token), newBytes);
    assert.deepEqual(await delivered(fixture.sourceFileId, token), sourceBytes);
    const artifactDirectory = process.env.IPAD_ARTIFACT_DIR ?? join(tmpdir(), "bookorbit-duplicate-merge-proof");
    await mkdir(artifactDirectory, { recursive: true });
    await writeFile(join(artifactDirectory, `merged-source-${fixture.sourceFileId}.pdf`), await delivered(fixture.sourceFileId, token));
    const deletion = await request("books", token, { bookIds: [pair.targetBookId] }, "DELETE");
    assert.equal(deletion.status, 204, await deletion.text());
    assert.equal((await request(`books/${pair.targetBookId}`, token)).status, 404);
    const replacementTitle = `Content after keeper deletion ${randomUUID()}`;
    const replacement = await PDFDocument.create();
    replacement.setTitle(replacementTitle);
    replacement.addPage([600, 800]).drawText("A deleted keeper cannot own newly scanned content", { x: 40, y: 700 });
    await mkdir(sourceDirectory, { recursive: true });
    await writeFile(join(sourceDirectory, "replacement.pdf"), await replacement.save());
    await scanLibrary(fixture.libraryId, token);
    const afterDeletion = await json("books/query", token, {
      q: replacementTitle,
      sort: [{ field: "title", dir: "asc" }],
      pagination: { page: 1, size: 10 },
    });
    assert.equal(afterDeletion.total, 1);
    assert.notEqual(afterDeletion.items[0].id, pair.targetBookId);
    assert.notEqual(afterDeletion.items[0].id, pair.sourceBookId);
    assert.equal((await request(`books/${pair.targetBookId}`, token)).status, 404);
  } finally {
    await json("auth/logout", undefined, { refreshToken: owner.refreshToken });
    await json("auth/logout", undefined, { refreshToken: restricted.refreshToken });
  }
});

test("IPAD-E03-A05-audio-guard: distinct recordings refuse timeline remapping while source audio plus target ebook is allowed", async () => {
  const { audioConflict: fixture } = JSON.parse(await readFile(process.env.IPAD_MERGE_FIXTURE, "utf8"));
  assert.ok(fixture, "Dedicated real audio fixture is required");
  const owner = await login("ipad-owner");
  const token = owner.accessToken;
  const pair = { sourceBookId: fixture.sourceBookId, targetBookId: fixture.targetBookId };
  try {
    const beforeSource = await deliveredAudio(pair.sourceBookId, token);
    const beforeTarget = await deliveredAudio(pair.targetBookId, token);
    const bookmark = await json(`audiobooks/${pair.sourceBookId}/bookmarks`, token, {
      positionMs: 250,
      title: "Original recording position",
      clientId: randomUUID(),
    });
    const preview = await json("book-duplicates/merge/preview", token, pair);
    assert.equal(preview.canApply, false);
    assert.ok(preview.blockers.some((value) => value.includes("distinct audio timelines")));
    assert.equal((await request("book-duplicates/merge/apply", token, { ...pair, previewToken: preview.previewToken })).status, 409);
    assert.ok(
      (await json(`audiobooks/${pair.sourceBookId}/bookmarks`, token)).some(
        (item) => item.id === bookmark.id && item.positionMs === bookmark.positionMs,
      ),
    );
    assert.deepEqual(await deliveredAudio(pair.sourceBookId, token), beforeSource);
    assert.deepEqual(await deliveredAudio(pair.targetBookId, token), beforeTarget);
    assert.equal((await request(`books/files/${fixture.targetAudioFileId}`, token, undefined, "DELETE")).status, 204);
    const sourceAudioOnly = await json("book-duplicates/merge/preview", token, pair);
    assert.equal(sourceAudioOnly.canApply, true, sourceAudioOnly.blockers.join("; "));
    assert.equal(sourceAudioOnly.filesPreserved, 3);
  } finally {
    await json("auth/logout", undefined, { refreshToken: owner.refreshToken });
  }
});
