import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { performance } from "node:perf_hooks";
import { test } from "node:test";

const base = process.env.IPAD_PDF_INK_API_URL ?? "http://localhost:16482/api/v1";
async function request(path, token, body, method = body ? "POST" : "GET") {
  return fetch(`${base}/${path}`, {
    method,
    headers: { ...(token ? { Authorization: `Bearer ${token}` } : {}), ...(body ? { "Content-Type": "application/json" } : {}) },
    ...(body ? { body: JSON.stringify(body) } : {}),
  });
}
async function login(username) {
  const response = await request("auth/login", null, {
    username,
    password: "IpadFixture123",
    clientKind: "native",
    deviceLabel: "PDF scale fixture",
  });
  assert.equal(response.status, 200);
  return response.json();
}
async function inspect(token) {
  const response = await request("annotations/native/files/1/source?bookId=1&page=0", token);
  assert.equal(response.status, 200, await response.clone().text());
  return response.json();
}
async function change(token, mode) {
  const response = await request(`__faults/source-pdf/source/1/${mode}`, token, null, "POST");
  assert.equal(response.status, 204, await response.clone().text());
}

test("IPAD-E02-A02/A06-PDF-SCALE: repeated inspection of a large source stays cheap and changed/deleted/protected files invalidate facts with fresh authorization", async () => {
  const owner = await login("ipad-owner");
  const reader = await login("ipad-reader");
  const restricted = await login("ipad-restricted");
  const token = owner.accessToken;
  try {
    await change(token, "large");
    const artifact = await request("books/files/1/serve", token);
    assert.equal(artifact.status, 200);
    assert.ok(Number(artifact.headers.get("content-length")) >= 24 * 1024 * 1024);
    await artifact.body.cancel();
    const coldStarted = performance.now();
    const initial = await inspect(token);
    const coldMs = performance.now() - coldStarted;
    assert.equal(initial.width, 600);
    assert.equal(initial.height, 800);
    assert.equal(initial.canEditPdfInk, true);
    const pollStarted = performance.now();
    for (let poll = 0; poll < 12; poll++) assert.deepEqual(await inspect(token), initial);
    const pollMs = performance.now() - pollStarted;
    const relativeBudgetMs = Math.max(350, coldMs * 4);
    assert.ok(pollMs <= 3000, `12 unchanged PDF inspection requests took ${pollMs.toFixed(1)} ms, exceeding the 3000 ms budget`);
    assert.ok(
      pollMs <= relativeBudgetMs,
      `12 unchanged polls took ${pollMs.toFixed(1)} ms; initial inspection ${coldMs.toFixed(1)} ms gives a ${relativeBudgetMs.toFixed(1)} ms polling budget`,
    );
    console.log(
      JSON.stringify({
        testId: "IPAD-E02-A02/A06-PDF-SCALE",
        sourceBytes: Number(artifact.headers.get("content-length")),
        coldMs,
        pollMs,
        polls: 12,
        relativeBudgetMs,
        absoluteBudgetMs: 3000,
      }),
    );
    const viewer = await inspect(reader.accessToken);
    assert.equal(viewer.sourceRevision, initial.sourceRevision);
    assert.equal(viewer.canEditPdfInk, false, "warm factual metadata does not cache the owner's permission");
    assert.equal((await request("annotations/native/files/1/source?bookId=1&page=0", restricted.accessToken)).status, 403);
    await change(token, "replace");
    const replaced = await inspect(token);
    assert.notEqual(replaced.sourceRevision, initial.sourceRevision);
    assert.notEqual(replaced.pageFingerprint, initial.pageFingerprint);
    assert.equal(replaced.width, 420);
    assert.equal(replaced.height, 600);
    await change(token, "delete");
    assert.equal((await request("annotations/native/files/1/source?bookId=1&page=0", token)).status, 404);
    await change(token, "restore");
    await change(token, "protect");
    assert.equal((await inspect(token)).canEditPdfInk, false);
    await change(token, "restore");
    const writable = await inspect(token);
    assert.equal(writable.canEditPdfInk, true);
    const clientId = randomUUID();
    const create = await request("annotations/native/operations", token, {
      deviceId: "source-cache-fixture",
      operations: [
        {
          operationId: randomUUID(),
          clientId,
          bookId: 1,
          baseVersion: 0,
          action: "create",
          payload: {
            kind: "pdf_ink",
            bookFileId: 1,
            text: "",
            sourceRevision: writable.sourceRevision,
            pageFingerprint: writable.pageFingerprint,
            pdf: { page: 0, rect: { x: 80, y: 600, width: 100, height: 8 }, rects: [] },
            drawing: {
              format: "bookorbit-ink-v1",
              strokes: [
                {
                  id: "cache-publication",
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
        },
      ],
    });
    assert.equal(create.status, 201, await create.clone().text());
    const created = (await create.json()).results[0];
    assert.equal(created.publication.status, "published");
    const published = await inspect(token);
    assert.equal(published.sourceRevision, created.publication.sourceRevision);
    assert.notEqual(published.sourceRevision, writable.sourceRevision);
    assert.equal(published.pageFingerprint, writable.pageFingerprint, "publishing only ink preserves page content fingerprints");
    const remove = await request("annotations/native/operations", token, {
      deviceId: "source-cache-fixture",
      operations: [
        {
          operationId: randomUUID(),
          clientId,
          annotationId: created.annotation.id,
          bookId: 1,
          baseVersion: created.annotation.version,
          action: "delete",
          payload: { sourceRevision: published.sourceRevision, pageFingerprint: published.pageFingerprint },
        },
      ],
    });
    assert.equal(remove.status, 201, await remove.clone().text());
    const removed = (await remove.json()).results[0];
    assert.equal(removed.publication.status, "published");
    assert.equal((await inspect(token)).sourceRevision, removed.publication.sourceRevision);
  } finally {
    await change(token, "restore");
  }
});
