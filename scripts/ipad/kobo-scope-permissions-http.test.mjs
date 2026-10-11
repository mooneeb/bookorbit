import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { test } from "node:test";

const target = process.env.IPAD_E04_BASE_URL;
if (!target || !["localhost", "127.0.0.1"].includes(new URL(target).hostname)) {
  throw new Error("Kobo scope permission tests require the isolated IPAD_E04_BASE_URL");
}
const base = target.replace(/\/$/, "");
async function request(path, token, method = "GET", body) {
  return fetch(`${base}/api/v1/${path}`, {
    method,
    headers: { ...(token ? { authorization: `Bearer ${token}` } : {}), ...(body ? { "content-type": "application/json" } : {}) },
    ...(body ? { body: JSON.stringify(body) } : {}),
    signal: AbortSignal.timeout(20_000),
  });
}
async function json(path, token, method = "GET", body) {
  const response = await request(path, token, method, body);
  assert.equal(response.ok, true, `${method} ${path}: ${await response.clone().text()}`);
  return response.json();
}
async function login(username) {
  return (await json("auth/login", undefined, "POST", { username, password: "IpadFixture123" })).accessToken;
}

test("IPAD-E04-A03 smart-scope Kobo changes require permission and ordinary rename preserves subscription", async () => {
  const restricted = await login("ipad-restricted");
  const owner = await login("ipad-owner");
  const name = `Scope permission ${randomUUID()}`;
  assert.equal((await request("smart-scopes", restricted, "POST", { name, icon: "Folder", syncToKobo: true })).status, 403);
  const scope = await json("smart-scopes", restricted, "POST", { name, icon: "Folder", syncToKobo: false });
  try {
    for (const enabled of [true, false]) {
      assert.equal((await request(`smart-scopes/${scope.id}/kobo-sync`, restricted, "PUT", { enabled })).status, 403);
    }
    assert.equal((await request(`smart-scopes/${scope.id}`, restricted, "PATCH", { syncToKobo: true })).status, 403);
    const renamed = await json(`smart-scopes/${scope.id}`, restricted, "PATCH", { name: `${name} renamed`, syncToKobo: false });
    assert.equal(renamed.syncToKobo, false);
    await json(`smart-scopes/${scope.id}`, owner, "PATCH", { syncToKobo: true });
    assert.equal((await request(`smart-scopes/${scope.id}`, restricted, "PATCH", { syncToKobo: false })).status, 403);
    assert.equal((await json(`smart-scopes/${scope.id}`, restricted)).syncToKobo, true);
  } finally {
    assert.equal((await request(`smart-scopes/${scope.id}`, restricted, "DELETE")).status, 204);
  }
});

test("IPAD-E04-A03 permitted owner can toggle Kobo subscription and private non-owner is denied", async () => {
  const owner = await login("ipad-owner");
  const other = await login("ipad-reader");
  const scope = await json("smart-scopes", owner, "POST", { name: `Owned Kobo ${randomUUID()}`, icon: "Folder", syncToKobo: true });
  try {
    for (const enabled of [false, true]) {
      const result = await json(`smart-scopes/${scope.id}/kobo-sync`, owner, "PUT", { enabled });
      assert.equal(result.syncToKobo, enabled);
      assert.equal(result.koboSyncEnabled, enabled);
      assert.equal((await json(`smart-scopes/${scope.id}`, owner)).syncToKobo, enabled);
    }
    assert.equal((await request(`smart-scopes/${scope.id}`, other, "PATCH", { syncToKobo: false })).status, 403);
    assert.equal((await request(`smart-scopes/${scope.id}/kobo-sync`, other, "PUT", { enabled: true })).status, 403);
  } finally {
    assert.equal((await request(`smart-scopes/${scope.id}`, owner, "DELETE")).status, 204);
  }
});
