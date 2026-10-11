import assert from "node:assert/strict";
import { test } from "node:test";
import { json, login, request } from "./e05-http-support.mjs";

test("IPAD-E05-A02-http-session-revocation: another user's sessions stay private and revoked renewal is rejected", async () => {
  const owner = await login();
  const reader = await login("ipad-reader");
  const disposable = await login("ipad-owner", { fresh: true, deviceLabel: "E05 revocation target" });
  const sessions = await json("auth/sessions", owner.accessToken);
  const target = sessions.find((session) => session.deviceLabel === "E05 revocation target");
  assert.ok(target, "The native transport must persist its named session");
  const privateSessions = await json("auth/sessions", reader.accessToken);
  assert.equal(
    privateSessions.some((session) => session.id === target.id),
    false,
  );
  assert.equal((await request(`auth/sessions/${target.id}`, reader.accessToken, "DELETE")).status, 403);
  await json(`auth/sessions/${target.id}`, owner.accessToken, "DELETE", undefined, 204);
  assert.equal((await request("auth/refresh", undefined, "POST", { refreshToken: disposable.refreshToken })).status, 401);
  assert.equal(
    (await json("auth/sessions", owner.accessToken)).some((session) => session.id === target.id),
    false,
  );
  assert.equal((await json("auth/me", reader.accessToken)).username, "ipad-reader");
});
