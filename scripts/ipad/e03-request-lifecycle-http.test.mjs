import { test } from "node:test";
import assert from "node:assert/strict";
import { createRequire } from "node:module";
const require = createRequire(new URL("../../server/package.json", import.meta.url));
const { PDFDocument } = require("pdf-lib");
const protocol = process.env.IPAD_E03_PROTOCOL_URL ?? "http://127.0.0.1:16502";
const base = process.env.IPAD_API_BASE ?? "http://localhost:16482/api/v1";
async function request(path, { token, body, method = body ? "POST" : "GET" } = {}) {
  return fetch(`${base}/${path}`, {
    method,
    headers: { ...(token ? { Authorization: `Bearer ${token}` } : {}), ...(body ? { "Content-Type": "application/json" } : {}) },
    body: body ? JSON.stringify(body) : undefined,
  });
}
async function login(username) {
  const response = await request("auth/login", {
    body: { username, password: "IpadFixture123", clientKind: "native", deviceLabel: "request lifecycle HTTP" },
  });
  assert.equal(response.status, 200);
  return response.json();
}
async function json(response, status = 200) {
  assert.equal(response.status, status, await response.clone().text());
  return response.json();
}

test("IPAD-E03-A02-HTTP-01: discovery/create/join/unsubscribe/cancel remain user scoped and bounded", async () => {
  const owner = await login("ipad-owner");
  const reader = await login("ipad-reader");
  const restricted = await login("ipad-restricted");
  const libraries = await json(await request("libraries", { token: owner.accessToken }));
  const destination = libraries.find((library) => library.name === "Fixture library");
  assert.ok(destination, "The owner must have an accessible Fixture library destination");
  const title = `Request lifecycle ${Date.now()}`;
  const body = { title, authors: ["Fixture Author"], mediaKind: "ebook", targetLibraryId: destination.id };
  assert.equal((await request("book-requests", { body, token: restricted.accessToken })).status, 403);
  assert.equal((await request("book-requests", { body: { ...body, unexpected: true }, token: owner.accessToken })).status, 400);
  const created = await json(await request("book-requests", { body, token: owner.accessToken }), 201);
  assert.equal(created.subscribed, false);
  assert.equal(created.request.targetLibraryId, destination.id);
  const id = created.request.id;
  const availability = await json(
    await request("book-requests/availability", {
      token: reader.accessToken,
      body: { items: [{ title, author: "Fixture Author", mediaKind: "ebook" }] },
    }),
  );
  assert.equal(availability[0].existingRequestId, id);
  assert.equal(availability[0].alreadySubscribed, false);
  const joined = await json(await request("book-requests", { body, token: reader.accessToken }), 201);
  assert.equal(joined.subscribed, true);
  assert.equal(joined.request.id, id);
  const page = await json(await request("book-requests?limit=1&page=1", { token: reader.accessToken }));
  assert.ok(page.items.length <= 1);
  assert.ok(page.items.some((item) => item.id === id));
  assert.equal((await request(`book-requests/${id}/cancel`, { method: "POST", token: reader.accessToken })).status, 403);
  assert.equal((await request(`book-request-fulfilment/${id}/releases`, { token: reader.accessToken })).status, 403);
  assert.equal((await request(`book-requests/${id}/subscription`, { method: "DELETE", token: reader.accessToken })).status, 204);
  assert.equal((await request(`book-requests/${id}`, { token: reader.accessToken })).status, 403);
  const cancelled = await json(await request(`book-requests/${id}/cancel`, { method: "POST", token: owner.accessToken }));
  assert.equal(cancelled.status, "cancelled");
  assert.equal((await request(`book-requests/${id}/cancel`, { method: "POST", token: owner.accessToken })).status, 400);
});

test("IPAD-E03-A02-HTTP-02: controlled source/client self-fulfilment delivers an actual readable PDF", async () => {
  const owner = await login("ipad-owner");
  const result = await json(
    await request("book-requests", {
      token: owner.accessToken,
      body: {
        title: `HTTP requested fixture ${Date.now()}`,
        mediaKind: "ebook",
        selfServe: true,
        targetLibraryId: 1,
        targetFolderId: 1,
        preferredFormats: ["pdf"],
      },
    }),
    201,
  );
  const id = result.request.id;
  await fetch(`${protocol}/control?failSearch=true`);
  const unavailable = await json(await request(`book-request-fulfilment/${id}/releases?refresh=true`, { token: owner.accessToken }));
  assert.ok(
    unavailable.indexers.some((source) => !source.ok),
    "source failure is reported separately from empty results",
  );
  await fetch(`${protocol}/control?reset=true`);
  const releases = await json(await request(`book-request-fulfilment/${id}/releases?refresh=true`, { token: owner.accessToken }));
  assert.ok(releases.releases.length > 0, "controlled source release must be configured");
  const release = releases.releases[0];
  await fetch(`${protocol}/control?failAdd=true`);
  const refused = await request(`book-request-fulfilment/${id}/grab`, {
    token: owner.accessToken,
    body: { indexerId: release.indexerId, releaseGuid: release.guid },
  });
  assert.ok(refused.status >= 400, "controlled client failure must reach the user");
  await fetch(`${protocol}/control?reset=true`);
  await json(
    await request(`book-request-fulfilment/${id}/grab`, {
      token: owner.accessToken,
      body: { indexerId: release.indexerId, releaseGuid: release.guid },
    }),
  );
  const deadline = Date.now() + 90_000;
  let settled;
  while (Date.now() < deadline) {
    settled = await json(await request(`book-requests/${id}`, { token: owner.accessToken }));
    if (settled.status === "needs_review") {
      const review = await json(await request(`book-request-fulfilment/${id}/review`, { token: owner.accessToken }));
      assert.ok(review.files.length > 0);
      assert.equal(review.canFile, true);
      settled = await json(await request(`book-request-fulfilment/${id}/force-file`, { method: "POST", token: owner.accessToken }));
    }
    if (settled.status === "available") break;
    assert.notEqual(settled.status, "failed", settled.statusReason);
    await new Promise((resolve) => setTimeout(resolve, 250));
  }
  assert.equal(settled.status, "available");
  assert.ok(settled.matchedBookId > 0);
  const book = await json(await request(`books/${settled.matchedBookId}`, { token: owner.accessToken }));
  const file = book.files.find((item) => item.format === "pdf");
  assert.ok(file, "delivery exposes PDF to native and browser readers");
  const response = await request(`books/files/${file.id}/serve`, { token: owner.accessToken });
  assert.equal(response.status, 200);
  const pdf = await PDFDocument.load(await response.arrayBuffer());
  assert.ok(pdf.getPageCount() > 0);
});
