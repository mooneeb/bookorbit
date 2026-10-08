import assert from "node:assert/strict";
import { createHash, randomUUID } from "node:crypto";
import { test } from "node:test";

const base = process.env.IPAD_SOURCE_INK_API_URL ?? "http://localhost:16482/api/v1";
const route = (window = 1, limit = 100, page = 0) =>
  `annotations/native/source-ink/window?bookId=1&bookFileId=1&page=${page}&window=${window}&limit=${limit}`;

async function request(path, token, body, method = body ? "POST" : "GET") {
  return fetch(`${base}/${path}`, {
    method,
    headers: { ...(token ? { Authorization: `Bearer ${token}` } : {}), ...(body ? { "Content-Type": "application/json" } : {}) },
    ...(body ? { body: JSON.stringify(body) } : {}),
  });
}
async function json(response, expected = 200) {
  assert.equal(response.status, expected, await response.clone().text());
  return response.json();
}
async function login(username) {
  return (
    await json(
      await request("auth/login", null, { username, password: "IpadFixture123", clientKind: "native", deviceLabel: "Source ink window fixture" }),
    )
  ).accessToken;
}
async function mutate(token, operations) {
  return (await json(await request("annotations/native/source-ink/1/1/operations", token, { deviceId: "source-window-http", operations }), 201))
    .results;
}

test("IPAD-E02-A03-source-window: live shared ink beyond one hundred groups remains reachable in stable bounded windows", async () => {
  const owner = await login("ipad-owner");
  const reader = await login("ipad-reader");
  const restricted = await login("ipad-restricted");
  const initial = await json(await request(route(), owner));
  assert.equal((await request(route())).status, 401);
  assert.equal((await request(route(), restricted)).status, 403);
  for (const invalid of [
    route(0),
    route(1, 101),
    route(1, 0),
    route(1, 100, -1),
    route(1, 100, 0.5),
    route(1, 100, ""),
    `${route()}&unexpected=true`,
  ]) {
    assert.equal((await request(invalid, owner)).status, 400);
  }
  const source = await json(await request("annotations/native/files/1/source?bookId=1&page=0", owner));
  const baseline = await request("books/files/1/serve", owner);
  assert.equal(baseline.status, 200);
  const hash = (bytes) => createHash("sha256").update(bytes).digest("hex");
  const beforeHash = hash(Buffer.from(await baseline.arrayBuffer()));
  assert.equal((await request("__faults/source-pdf/source/1/snapshot", owner, undefined, "POST")).status, 204);
  const prefix = `window-http-${randomUUID()}`;
  const operations = Array.from({ length: 101 }, (_, index) => ({
    operationId: randomUUID(),
    clientId: randomUUID(),
    bookId: 1,
    baseVersion: 0,
    action: "create",
    payload: {
      kind: "pdf_ink",
      bookFileId: 1,
      pdf: { page: 0, rect: { x: 30, y: 60, width: 12, height: 12 }, rects: [] },
      drawing: {
        format: "bookorbit-ink-v1",
        strokes: [
          {
            id: `${prefix}-${index}`,
            points: [
              { x: 30, y: 60 },
              { x: 42, y: 72 },
            ],
            width: 1,
            color: "#336699",
          },
        ],
      },
      sourceRevision: source.sourceRevision,
      pageFingerprint: source.pageFingerprint,
    },
  }));
  const created = [];
  try {
    for (let offset = 0; offset < operations.length; offset += 100) {
      const results = await mutate(owner, operations.slice(offset, offset + 100));
      for (const result of results) {
        assert.equal(result.status, "applied");
        created.push(result.annotation);
        assert.equal(result.publication.status, "published", JSON.stringify(result.publication));
      }
    }
    const ids = [];
    const total = initial.total + 101;
    for (let window = 1; window <= Math.ceil(total / 100); window++) {
      const page = await json(await request(route(window), reader));
      assert.equal(page.total, total);
      assert.equal(page.window, window);
      assert.equal(page.limit, 100);
      assert.ok(page.items.length <= 100);
      assert.ok(page.items.every((item) => item.kind === "pdf_ink" && item.deletedAt === null && item.jumpFileId === 1 && item.pdf.page === 0));
      ids.push(...page.items.map((item) => item.id));
    }
    assert.equal(ids.length, total);
    assert.equal(new Set(ids).size, total);
    assert.deepEqual(
      ids,
      [...ids].sort((left, right) => left - right),
    );
    assert.ok(created.every((item) => ids.includes(item.id)));
    assert.deepEqual(
      (await json(await request(route(1), reader))).items.map((item) => item.id),
      ids.slice(0, 100),
    );
    const beyond = await json(await request(route(Math.ceil(total / 100) + 1), reader));
    assert.equal(beyond.total, total);
    assert.deepEqual(beyond.items, []);
  } finally {
    try {
      for (let offset = 0; offset < created.length; offset += 100) {
        const results = await mutate(
          owner,
          created.slice(offset, offset + 100).map((item) => ({
            operationId: randomUUID(),
            clientId: item.clientId,
            annotationId: item.id,
            bookId: 1,
            baseVersion: item.version,
            action: "delete",
          })),
        );
        assert.ok(results.every((item) => item.status === "applied" && item.publication?.status === "published"));
      }
    } finally {
      assert.equal((await request("__faults/source-pdf/source/1/restore", owner, undefined, "POST")).status, 204);
      const restored = await request("books/files/1/serve", owner);
      assert.equal(restored.status, 200);
      assert.equal(hash(Buffer.from(await restored.arrayBuffer())), beforeHash);
    }
  }
  assert.equal((await json(await request(route(), owner))).total, initial.total);
});
