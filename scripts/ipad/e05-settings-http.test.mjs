import assert from "node:assert/strict";
import { test } from "node:test";
import { json, login, request } from "./e05-http-support.mjs";

test("IPAD-E05-A03-http-admin-setting-roundtrip: the granted settings permission persists validated server configuration", async () => {
  const owner = await login();
  const administrator = await login("ipad-editor");
  assert.equal(administrator.user.isSuperuser, false);
  assert.ok(administrator.user.permissions.includes("manage_app_settings"));
  const before = await json("app-settings", owner.accessToken);
  const original = before.find((row) => row.key === "max_upload_size_mb");
  try {
    const saved = await json("app-settings/max_upload_size_mb", administrator.accessToken, "PATCH", { value: "251" });
    assert.equal(saved.value, "251");
    assert.equal((await json("app-settings", owner.accessToken)).find((row) => row.key === "max_upload_size_mb").value, "251");
    assert.equal((await request("app-settings/max_upload_size_mb", administrator.accessToken, "PATCH", { value: "invalid" })).status, 400);
  } finally {
    if (original) await json("app-settings/max_upload_size_mb", owner.accessToken, "PATCH", { value: original.value });
  }
});

test("IPAD-E05-A04-http-specific-permission-denials: reader and settings administrator cannot exceed their grants", async () => {
  const reader = await login("ipad-reader");
  const administrator = await login("ipad-editor");
  for (const [path, method, body] of [
    ["app-settings", "GET"],
    ["app-settings/max_upload_size_mb", "PATCH", { value: "252" }],
    ["users?page=0&pageSize=5", "GET"],
    ["auth/magic-links", "GET"],
  ])
    assert.equal((await request(path, reader.accessToken, method, body)).status, 403, path);
  for (const path of ["users?page=0&pageSize=5", "auth/magic-links", "achievements/admin/backfill/status"])
    assert.equal((await request(path, administrator.accessToken)).status, 403, path);
  assert.equal((await request("app-settings", administrator.accessToken)).status, 200);
});
