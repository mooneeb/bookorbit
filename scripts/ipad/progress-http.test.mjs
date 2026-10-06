import { test } from "node:test";
import assert from "node:assert/strict";

const base = process.env.IPAD_PROGRESS_API_URL ?? "http://localhost:16482/api/v1";
if (!["http://localhost:16482/api/v1", "http://localhost:16487/api/v1"].includes(base)) {
  throw new Error("Progress tests require their isolated localhost fixture");
}

async function request(path, { token, method = "GET", body } = {}) {
  return fetch(`${base}/${path}`, {
    method,
    headers: {
      ...(token ? { Authorization: `Bearer ${token}` } : {}),
      ...(body ? { "Content-Type": "application/json" } : {}),
    },
    ...(body ? { body: JSON.stringify(body) } : {}),
  });
}

async function login() {
  const response = await request("auth/login", {
    method: "POST",
    body: { username: "ipad-reader", password: "IpadFixture123", clientKind: "native", deviceLabel: "Concurrent reader fixture" },
  });
  assert.equal(response.status, 200);
  return response.json();
}

test("IPAD-E01-A03/A04: a text-page save preserves newer narration from another authenticated session", async () => {
  const textSession = await login();
  const narrationSession = await login();
  const path = "books/files/1/progress";
  async function save(token, body) {
    assert.equal((await request(path, { token, method: "POST", body })).status, 201);
  }
  try {
    assert.equal((await request(path, { token: textSession.accessToken, method: "DELETE" })).status, 204);
    await save(narrationSession.accessToken, {
      source: "narration",
      percentage: 10,
      positionSeconds: 4,
      mediaOverlayFragment: "chapter-one.xhtml#first",
      mediaOverlaySectionIndex: 0,
    });
    const snapshotResponse = await request(path, { token: textSession.accessToken });
    assert.equal(snapshotResponse.status, 200);
    assert.equal((await snapshotResponse.json()).positionSeconds, 4);
    await save(narrationSession.accessToken, {
      source: "narration",
      percentage: 20,
      positionSeconds: 9,
      mediaOverlayFragment: "chapter-one.xhtml#second",
      mediaOverlaySectionIndex: 0,
    });
    await save(textSession.accessToken, {
      source: "text",
      percentage: 66.666667,
      pageNumber: 2,
    });
    const result = await request(path, { token: textSession.accessToken });
    assert.equal(result.status, 200);
    const progress = await result.json();
    assert.equal(progress.pageNumber, 2);
    assert.ok(Math.abs(progress.percentage - 66.666667) < 0.00001);
    assert.equal(progress.positionSeconds, 9);
    assert.equal(progress.mediaOverlayFragment, "chapter-one.xhtml#second");
    assert.equal(progress.mediaOverlaySectionIndex, 0);
    assert.equal(progress.narrationPercentage, 20);
    await save(narrationSession.accessToken, {
      source: "narration",
      percentage: 20,
      positionSeconds: null,
      mediaOverlayFragment: null,
      mediaOverlaySectionIndex: null,
    });
    const clearedResponse = await request(path, { token: narrationSession.accessToken });
    assert.equal(clearedResponse.status, 200);
    const cleared = await clearedResponse.json();
    assert.equal(cleared.positionSeconds, null);
    assert.equal(cleared.mediaOverlayFragment, null);
    assert.equal(cleared.mediaOverlaySectionIndex, null);
    assert.equal(cleared.pageNumber, 2);
  } finally {
    assert.equal((await request(path, { token: textSession.accessToken, method: "DELETE" })).status, 204);
    for (const session of [textSession, narrationSession]) {
      assert.equal((await request("auth/logout", { method: "POST", body: { refreshToken: session.refreshToken } })).status, 200);
    }
  }
});
