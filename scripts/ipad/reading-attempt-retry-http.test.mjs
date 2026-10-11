import { test } from "node:test";
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";

const base = process.env.IPAD_E04_API_URL ?? "http://127.0.0.1:16502/api/v1";
if (!/^http:\/\/(localhost|127\.0\.0\.1):\d+\/api\/v1$/.test(base)) throw new Error("Reading attempt tests require an isolated localhost fixture");
const bookID = Number(process.env.IPAD_READING_ATTEMPT_BOOK_ID ?? 4);
const otherBookID = Number(process.env.IPAD_READING_ATTEMPT_OTHER_BOOK_ID ?? (bookID === 5 ? 6 : 5));

async function request(path, { token, method = "GET", body } = {}) {
  return fetch(`${base}/${path}`, {
    method,
    headers: { ...(token ? { Authorization: `Bearer ${token}` } : {}), ...(body ? { "Content-Type": "application/json" } : {}) },
    ...(body ? { body: JSON.stringify(body) } : {}),
  });
}

const username = process.env.IPAD_READING_ATTEMPT_USERNAME ?? "ipad-e04-attempts";

async function login(account = username, clientKind = "native") {
  const response = await request("auth/login", {
    method: "POST",
    body: { username: account, password: "IpadFixture123", clientKind, deviceLabel: "Reading attempt retry fixture" },
  });
  assert.equal(response.status, 200);
  return response.json();
}

test("IPAD-E04-A01-HISTORY-RETRY: lost create receipt, stale edit, ownership and deletion preserve history", async () => {
  const native = await login();
  const web = await login(username, "web");
  const foreign = await login("ipad-e04-insights-viewer", "web");
  const token = native.accessToken;
  const path = `books/${bookID}/reading-attempts`;
  const body = { clientId: randomUUID(), startedOn: "2026-01-01", endedOn: "2026-01-02", outcome: "completed" };
  const before = await (await request(`${path}?page=1&pageSize=100`, { token })).json();
  let attempt;
  let legacyAttempt;
  try {
    const discarded = await request(path, { token, method: "POST", body });
    assert.equal(discarded.status, 201);
    await discarded.body.cancel();
    const retries = await Promise.all([request(path, { token, method: "POST", body }), request(path, { token, method: "POST", body })]);
    assert.deepEqual(
      retries.map((response) => response.status),
      [201, 201],
    );
    const acknowledged = await Promise.all(retries.map((response) => response.json()));
    attempt = acknowledged[0];
    assert.deepEqual(acknowledged[1], attempt);
    assert.equal(attempt.externalId, body.clientId);
    assert.equal(attempt.origin, "manual");
    assert.equal(attempt.startedOn, "2026-01-01");
    assert.equal(attempt.endedOn, "2026-01-02");
    const after = await (await request(`${path}?page=1&pageSize=100`, { token })).json();
    assert.equal(after.total - before.total, 1);
    assert.equal(after.items.filter((item) => item.externalId === body.clientId).length, 1);
    assert.deepEqual(await (await request(`${path}/${attempt.id}`, { token })).json(), attempt);
    assert.equal((await request(`books/${otherBookID}/reading-attempts`, { token, method: "POST", body })).status, 409);
    assert.equal((await request(path, { token, method: "POST", body: { ...body, clientId: null } })).status, 400);

    const legacyCreate = await request(path, {
      token,
      method: "POST",
      body: { startedOn: "2025-12-01", endedOn: "2025-12-02", outcome: "completed" },
    });
    assert.equal(legacyCreate.status, 201);
    legacyAttempt = await legacyCreate.json();
    assert.equal(legacyAttempt.externalId, null);
    assert.equal(legacyAttempt.externalProvider, null);
    assert.equal((await request(`${path}/${legacyAttempt.id}`, { token, method: "DELETE" })).status, 204);
    legacyAttempt = undefined;

    const webEdit = await request(`${path}/${attempt.id}`, { token: web.accessToken, method: "PATCH", body: { endedOn: "2026-01-03" } });
    assert.equal(webEdit.status, 200);
    let current = await webEdit.json();
    assert.equal(
      (await request(`${path}/${attempt.id}`, { token, method: "PATCH", body: { endedOn: "2026-01-04", baseUpdatedAt: null } })).status,
      400,
    );
    assert.notEqual(current.updatedAt, attempt.updatedAt);
    const stale = await request(`${path}/${attempt.id}`, {
      token,
      method: "PATCH",
      body: { endedOn: "2026-01-04", baseUpdatedAt: attempt.updatedAt },
    });
    assert.equal(stale.status, 409);
    const conflict = await stale.json();
    assert.equal(conflict.errorCode, "READING_ATTEMPT_CONFLICT");
    assert.deepEqual(conflict.current, current);
    assert.deepEqual(await (await request(`${path}/${attempt.id}`, { token })).json(), current);

    const matchingPatch = { endedOn: "2026-01-04", baseUpdatedAt: current.updatedAt };
    const lostPatchReceipt = await request(`${path}/${attempt.id}`, { token, method: "PATCH", body: matchingPatch });
    assert.equal(lostPatchReceipt.status, 200);
    await lostPatchReceipt.body.cancel();
    assert.equal((await request(`${path}/${attempt.id}`, { token, method: "PATCH", body: matchingPatch })).status, 409);
    const acknowledgedPatch = await request(`${path}/${attempt.id}`, { token });
    assert.equal(acknowledgedPatch.status, 200);
    const recovered = await acknowledgedPatch.json();
    assert.equal(recovered.endedOn, "2026-01-04");
    assert.equal(recovered.startedOn, current.startedOn);
    assert.equal(recovered.outcome, current.outcome);
    assert.notEqual(recovered.updatedAt, current.updatedAt);
    current = recovered;
    const statusBeforeRetry = (await (await request(`books/${bookID}`, { token })).json()).readStatus;
    const oldCreateRetry = await request(path, { token, method: "POST", body });
    assert.equal(oldCreateRetry.status, 201);
    assert.deepEqual(await oldCreateRetry.json(), current);
    assert.deepEqual((await (await request(`books/${bookID}`, { token })).json()).readStatus, statusBeforeRetry);

    assert.equal((await request(`${path}/${attempt.id}`, { token: foreign.accessToken })).status, 404);
    assert.equal(
      (
        await request(`${path}/${attempt.id}`, {
          token: foreign.accessToken,
          method: "PATCH",
          body: { endedOn: "2026-01-05", baseUpdatedAt: current.updatedAt },
        })
      ).status,
      404,
    );
    const deleteResponse = await request(`${path}/${attempt.id}`, { token, method: "DELETE" });
    assert.equal(deleteResponse.status, 204);
    assert.equal((await request(`${path}/${attempt.id}`, { token })).status, 404);
    assert.equal(
      (await request(`${path}/${attempt.id}`, { token, method: "PATCH", body: { endedOn: "2026-01-05", baseUpdatedAt: current.updatedAt } })).status,
      404,
    );
    assert.equal((await request(path, { token, method: "POST", body })).status, 409);
    const deleted = await (await request(`${path}?page=1&pageSize=100`, { token })).json();
    assert.equal(deleted.total, before.total);
    assert.ok(!deleted.items.some((item) => item.id === attempt.id || item.externalId === body.clientId));
  } finally {
    if (attempt) await request(`${path}/${attempt.id}`, { token, method: "DELETE" });
    if (legacyAttempt) await request(`${path}/${legacyAttempt.id}`, { token, method: "DELETE" });
    for (const session of [native, web, foreign]) await request("auth/logout", { method: "POST", body: { refreshToken: session.refreshToken } });
  }
});
