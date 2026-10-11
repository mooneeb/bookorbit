import assert from "node:assert/strict";
import { test } from "node:test";
import { json, login, request } from "./e05-http-support.mjs";

test("IPAD-E05-A01-http-profile-scope: persisted profile, timezone and locale belong to the authenticated account", async () => {
  const owner = await login();
  const reader = await login("ipad-reader");
  const before = await json("auth/me", owner.accessToken);
  const readerBefore = await json("auth/me", reader.accessToken);
  const locale = await json("user-preferences/locale", owner.accessToken);
  try {
    const saved = await json("users/me", owner.accessToken, "PATCH", { name: "E05 HTTP Profile" });
    assert.equal(saved.name, "E05 HTTP Profile");
    await json("users/me/settings", owner.accessToken, "PATCH", { settings: { timezone: "Asia/Karachi" } });
    await json("user-preferences/locale", owner.accessToken, "PUT", { settings: { locale: "en" } }, 204);
    const after = await json("auth/me", owner.accessToken);
    assert.equal(after.name, "E05 HTTP Profile");
    assert.equal(after.settings.timezone, "Asia/Karachi");
    assert.equal((await json("user-preferences/locale", owner.accessToken)).settings.locale, "en");
    assert.equal((await json("auth/me", reader.accessToken)).name, readerBefore.name);
    assert.equal((await request("users/me", owner.accessToken, "PATCH", { name: "valid", unexpected: true })).status, 400);
    assert.equal((await request("users/me", undefined, "PATCH", { name: "anonymous" })).status, 401);
  } finally {
    await json("users/me", owner.accessToken, "PATCH", { name: before.name });
    await json("users/me/settings", owner.accessToken, "PATCH", { settings: { timezone: before.settings.timezone ?? "UTC" } });
    if (locale.settings && Object.keys(locale.settings).length) await json("user-preferences/locale", owner.accessToken, "PUT", locale, 204);
  }
});
