import { test } from "node:test";
import assert from "node:assert/strict";

const base = process.env.IPAD_E03_API_URL ?? "http://localhost:16482/api/v1";
async function request(path, token, body, method = body ? "POST" : "GET") {
  return fetch(`${base}/${path}`, {
    method,
    headers: { Authorization: `Bearer ${token}`, ...(body ? { "Content-Type": "application/json" } : {}) },
    body: body ? JSON.stringify(body) : undefined,
  });
}
async function login(username) {
  const response = await request("auth/login", "", {
    username,
    password: process.env.IPAD_FIXTURE_PASSWORD ?? "IpadFixture123",
    clientKind: "native",
    deviceLabel: "E03 scan seam",
  });
  assert.equal(response.status, 200);
  return response.json();
}

test("IPAD-E03-A01-scan-status: authenticated durable progress and bounded history reconcile without writes", async () => {
  const owner = await login("ipad-owner");
  const libraries = await (await request("libraries", owner.accessToken)).json();
  const library = libraries.find((entry) => entry.type === "books");
  assert.ok(library);
  const before = await (await request(`scanner/libraries/${library.id}/scan-history?limit=5`, owner.accessToken)).json();
  const response = await request(`scanner/libraries/${library.id}/scan-status`, owner.accessToken);
  assert.equal(response.status, 200);
  const { progress } = await response.json();
  if (before.length) {
    assert.equal(progress.jobId, before[0].id);
    assert.equal(progress.libraryId, library.id);
    assert.ok(["running", "completed", "failed"].includes(progress.status));
    for (const key of ["processed", "total", "added", "updated", "missing"]) assert.ok(Number.isInteger(progress[key]) && progress[key] >= 0);
  } else assert.equal(progress, null);
  const history = await (await request(`scanner/libraries/${library.id}/scan-history?limit=50000`, owner.accessToken)).json();
  assert.ok(history.length <= 5);
  assert.equal((await request(`scanner/libraries/${library.id}/scan-history?limit=invalid`, owner.accessToken)).status, 400);
  const reader = await login("ipad-reader");
  assert.equal((await request(`scanner/libraries/${library.id}/scan-status`, reader.accessToken)).status, 403);
  assert.equal((await request(`scanner/libraries/${library.id}/scan`, reader.accessToken, undefined, "POST")).status, 403);
  const after = await (await request(`scanner/libraries/${library.id}/scan-history?limit=5`, owner.accessToken)).json();
  assert.deepEqual(after, before);
});

test("IPAD-E03-A01-scan-retry: original baseline reuses accepted job after response loss and completion", async () => {
  const owner = await login("ipad-owner");
  const libraries = await (await request("libraries", owner.accessToken)).json();
  const library = libraries.find((entry) => entry.name === "E03 scan fixture");
  assert.ok(library, "The retained E03 harness must seed the controlled scan folder");
  const history = await (await request(`scanner/libraries/${library.id}/scan-history`, owner.accessToken)).json();
  const baseline = history[0]?.id ?? 0;
  const preview = await request("libraries/prescan", owner.accessToken, {
    libraryId: library.id,
    paths: (await (await request(`libraries/${library.id}`, owner.accessToken)).json()).folders.map((folder) => folder.path),
  });
  assert.equal(preview.status, 201);
  assert.ok((await preview.json()).totalFiles >= 1);
  const first = await request(`scanner/libraries/${library.id}/scan`, owner.accessToken, { expectedLastJobId: baseline });
  assert.equal(first.status, 202);
  const accepted = await first.json();
  assert.ok(accepted.jobId > baseline);
  const deadline = Date.now() + 20000;
  while (Date.now() < deadline) {
    const { progress } = await (await request(`scanner/libraries/${library.id}/scan-status`, owner.accessToken)).json();
    if (progress?.jobId === accepted.jobId && progress.status === "completed") break;
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  const retry = await request(`scanner/libraries/${library.id}/scan`, owner.accessToken, { expectedLastJobId: baseline });
  assert.equal(retry.status, 202);
  assert.deepEqual(await retry.json(), accepted);
  const after = await (await request(`scanner/libraries/${library.id}/scan-history`, owner.accessToken)).json();
  assert.equal(after[0].id, accepted.jobId);
  assert.equal(after[0].status, "completed");
  assert.equal((await request(`scanner/libraries/${library.id}/scan`, owner.accessToken, { expectedLastJobId: -1 })).status, 400);
  assert.equal(
    (await request(`scanner/libraries/${library.id}/scan`, owner.accessToken, { expectedLastJobId: baseline, invalid: true })).status,
    400,
  );
  const pageResponse = await request(`libraries/${library.id}/books`, owner.accessToken, { pagination: { page: 0, size: 40 } });
  assert.equal(pageResponse.status, 201);
  const page = await pageResponse.json();
  assert.equal(page.total, 1);
  const book = await (await request(`books/${page.items[0].id}`, owner.accessToken)).json();
  assert.equal(book.libraryId, library.id);
  assert.ok(book.files.some((file) => file.format === "pdf"));
  const file = book.files.find((file) => file.format === "pdf");
  const delivered = await request(`books/files/${file.id}/serve`, owner.accessToken);
  assert.equal(delivered.status, 200);
  assert.equal(
    Buffer.from(await delivered.arrayBuffer())
      .subarray(0, 5)
      .toString(),
    "%PDF-",
  );
  const progressPath = `books/files/${file.id}/progress`;
  assert.equal((await request(progressPath, owner.accessToken, { source: "text", percentage: 66.666667, pageNumber: 2 })).status, 201);
  const rescan = await request(`scanner/libraries/${library.id}/scan`, owner.accessToken, { expectedLastJobId: accepted.jobId });
  assert.equal(rescan.status, 202);
  const rescanned = await rescan.json();
  assert.ok(rescanned.jobId > accepted.jobId);
  const rescanDeadline = Date.now() + 20000;
  while (Date.now() < rescanDeadline) {
    const { progress } = await (await request(`scanner/libraries/${library.id}/scan-status`, owner.accessToken)).json();
    if (progress?.jobId === rescanned.jobId && progress.status === "completed") break;
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  const rescanStatus = await (await request(`scanner/libraries/${library.id}/scan-status`, owner.accessToken)).json();
  assert.equal(rescanStatus.progress.status, "completed");
  const preserved = await (await request(`books/${book.id}`, owner.accessToken)).json();
  assert.deepEqual(
    preserved.files.map((entry) => entry.id),
    book.files.map((entry) => entry.id),
  );
  assert.equal((await (await request(progressPath, owner.accessToken)).json()).pageNumber, 2);
  const reader = await login("ipad-reader");
  assert.equal((await (await request(progressPath, reader.accessToken)).json()).pageNumber, null);
});
