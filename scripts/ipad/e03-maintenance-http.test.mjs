import assert from "node:assert/strict";
import { test } from "node:test";
import { readFile } from "node:fs/promises";

const base = process.env.IPAD_BASE_URL ?? "http://localhost:16482/api/v1";
async function request(path, token, body) {
  return fetch(`${base}/${path}`, {
    method: body ? "POST" : "GET",
    headers: { ...(token ? { Authorization: `Bearer ${token}` } : {}), ...(body ? { "Content-Type": "application/json" } : {}) },
    body: body ? JSON.stringify(body) : undefined,
  });
}
async function login(username) {
  const response = await request("auth/login", null, {
    username,
    password: process.env.IPAD_TEST_PASSWORD ?? "IpadFixture123",
    clientKind: "native",
    deviceLabel: "Maintenance HTTP proof",
  });
  assert.equal(response.status, 200);
  return response.json();
}
async function json(path, token, body, status = 200) {
  const response = await request(path, token, body);
  assert.equal(response.status, status, `${path}: ${await response.clone().text()}`);
  return response.json();
}

test("IPAD-E03-A05-maintenance-repair: preview is read-only, exact file identity survives apply and retry, unauthorized repair is denied", async () => {
  assert.ok(process.env.IPAD_MAINTENANCE_FIXTURE, "IPAD_MAINTENANCE_FIXTURE is required");
  const fixture = JSON.parse(process.env.IPAD_MAINTENANCE_FIXTURE);
  const owner = await login("ipad-owner");
  const reader = await login("ipad-reader");
  const token = owner.accessToken;
  const body = { bookId: fixture.missingBookId, fileId: fixture.missingFileId, replacementPath: fixture.replacementPath };
  const expectedBytes = await readFile(body.replacementPath);
  assert.equal(
    (await request(`books/files/${body.fileId}/progress`, reader.accessToken, { source: "text", percentage: 50, pageNumber: 1 })).status,
    201,
  );
  const progressBefore = await json(`books/files/${body.fileId}/progress`, reader.accessToken);
  const note = await fetch(`${base}/books/${body.bookId}/personal-note`, {
    method: "PATCH",
    headers: { Authorization: `Bearer ${reader.accessToken}`, "Content-Type": "application/json" },
    body: JSON.stringify({ note: "Private note survives missing-file repair" }),
  });
  assert.equal(note.status, 200);
  const readerBefore = await json(`books/${body.bookId}`, reader.accessToken);
  const annotationsBefore = await json(`books/${body.bookId}/annotations?page=1&pageSize=100`, reader.accessToken);
  const detail = await json(`books/${body.bookId}`, token);
  const denied = await request("maintenance/missing-resources/files/preview", reader.accessToken, body);
  assert.equal(denied.status, 403);
  const preview = await json("maintenance/missing-resources/files/preview", token, body, 201);
  assert.equal(preview.fileId, body.fileId);
  assert.equal(preview.alreadyApplied, false);
  assert.equal((await request(`books/files/${body.fileId}/serve`, token)).status, 404);
  assert.equal((await request("maintenance/missing-resources/files/repair", token, { ...body, previewToken: "stale" })).status, 409);
  assert.equal((await request("maintenance/missing-resources/files/preview", token, { ...body, replacementPath: "/etc/passwd" })).status, 403);
  const applied = await json("maintenance/missing-resources/files/repair", token, { ...body, previewToken: preview.previewToken }, 201);
  assert.equal(applied.repaired, true);
  const repeated = await json("maintenance/missing-resources/files/repair", token, { ...body, previewToken: preview.previewToken }, 201);
  assert.equal(repeated.alreadyApplied, true);
  const after = await json(`books/${body.bookId}`, token);
  assert.equal(after.title, detail.title);
  assert.deepEqual(
    after.files.map((file) => file.id),
    detail.files.map((file) => file.id),
  );
  const delivered = await request(`books/files/${body.fileId}/serve`, token);
  assert.equal(delivered.status, 200);
  assert.match(delivered.headers.get("content-type"), /^application\/pdf/);
  const bytes = Buffer.from(await delivered.arrayBuffer());
  assert.match(bytes.subarray(0, 5).toString(), /^%PDF-/);
  assert.equal(bytes.length, preview.sizeBytes);
  assert.deepEqual(bytes, expectedBytes, "Every source-PDF byte, including embedded ink, survives relink");
  assert.deepEqual(await json(`books/files/${body.fileId}/progress`, reader.accessToken), progressBefore);
  const readerAfter = await json(`books/${body.bookId}`, reader.accessToken);
  assert.equal(readerAfter.personalNote, readerBefore.personalNote);
  assert.equal(readerAfter.personalNote, "Private note survives missing-file repair");
  assert.equal(after.personalNote, null, "Owner cannot read another user's private note");
  assert.deepEqual(await json(`books/${body.bookId}/annotations?page=1&pageSize=100`, reader.accessToken), annotationsBefore);
});
