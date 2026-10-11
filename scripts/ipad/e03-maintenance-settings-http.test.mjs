import assert from "node:assert/strict";
import { test } from "node:test";

const base = process.env.IPAD_BASE_URL ?? "http://localhost:16482/api/v1";
async function request(path, token, method = "GET", body) {
  return fetch(`${base}/${path}`, {
    method,
    headers: { ...(token ? { Authorization: `Bearer ${token}` } : {}), ...(body ? { "Content-Type": "application/json" } : {}) },
    body: body ? JSON.stringify(body) : undefined,
  });
}
async function login(username) {
  const response = await request("auth/login", null, "POST", {
    username,
    password: process.env.IPAD_TEST_PASSWORD ?? "IpadFixture123",
    clientKind: "native",
    deviceLabel: "Maintenance settings proof",
  });
  assert.equal(response.status, 200);
  return (await response.json()).accessToken;
}
async function json(path, token, method = "GET", body, status = 200) {
  const response = await request(path, token, method, body);
  assert.equal(response.status, status, `${path}: ${await response.clone().text()}`);
  return response.json();
}

test("IPAD-E03-A05-baseline-maintenance: permissions, exact setting validation, observable bounded work and idempotent backfill retry", async () => {
  const owner = await login("ipad-owner");
  const reader = await login("ipad-reader");
  const administrator = await login("ipad-settings-admin");
  assert.equal((await request("app-settings", administrator)).status, 200);
  for (const [path, method] of [
    ["achievements/admin/backfill", "POST"],
    ["achievements/admin/backfill/start", "POST"],
    ["achievements/admin/backfill/status", "GET"],
  ])
    assert.equal((await request(path, administrator, method)).status, 403, path);
  for (const [path, method, body] of [
    ["app-settings", "GET"],
    ["app-settings/max_upload_size_mb", "PATCH", { value: "250" }],
    ["books/embed-all", "POST"],
    ["books/embed-all/status", "GET"],
    ["achievements/admin/backfill", "POST"],
    ["achievements/admin/backfill/status", "GET"],
  ])
    assert.equal((await request(path, reader, method, body)).status, 403, path);
  const before = await json("app-settings", owner);
  const originals = new Map(before.map((row) => [row.key, row.value]));
  try {
    for (const value of ["0", "4097", "12.5", "12bad"]) {
      assert.equal((await request("app-settings/max_upload_size_mb", owner, "PATCH", { value })).status, 400);
    }
    assert.equal((await request("app-settings/update_check_enabled", owner, "PATCH", { value: "yes" })).status, 400);
    assert.equal((await request("app-settings/update_check_enabled", owner, "PATCH", { value: "true", unexpected: true })).status, 400);
    const upload = await json("app-settings/max_upload_size_mb", administrator, "PATCH", { value: "250" });
    assert.equal(upload.key, "max_upload_size_mb");
    assert.equal(upload.value, "250");
    assert.ok(Number.isInteger(upload.id));
    assert.ok(Number.isFinite(Date.parse(upload.updatedAt)));
    await json("app-settings/update_check_enabled", owner, "PATCH", { value: "false" });
    const after = await json("app-settings", owner);
    assert.equal(after.find((row) => row.key === "max_upload_size_mb").value, "250");
    assert.equal(after.find((row) => row.key === "update_check_enabled").value, "false");
    const embedding = await json("books/embed-all", owner, "POST", undefined, 201);
    assert.ok(Number.isInteger(embedding.queued));
    const embeddingStatus = await json("books/embed-all/status", owner);
    assert.ok(["idle", "running", "completed", "failed", "disabled"].includes(embeddingStatus.status));
    const started = await json("achievements/admin/backfill/start", owner, "POST", undefined, 201);
    assert.ok(started.runId);
    let outcome;
    const deadline = Date.now() + 120_000;
    do {
      outcome = await json("achievements/admin/backfill/status", owner);
      if (outcome.status !== "running") break;
      await new Promise((resolve) => setTimeout(resolve, 100));
    } while (Date.now() < deadline);
    assert.equal(outcome.status, "completed");
    assert.equal(outcome.failed, 0);
    assert.ok(outcome.processed >= 1);
    const repeated = await json("achievements/admin/backfill", owner, "POST", undefined, 201);
    assert.equal(repeated.awardsGranted, 0, "Replaying completed backfill must not duplicate awards");
  } finally {
    for (const key of ["max_upload_size_mb", "update_check_enabled"]) {
      if (originals.has(key)) await json(`app-settings/${key}`, owner, "PATCH", { value: originals.get(key) });
    }
  }
});
