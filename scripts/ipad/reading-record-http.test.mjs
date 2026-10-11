import { test } from "node:test";
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";

const base = process.env.IPAD_READING_RECORD_API_URL ?? "http://127.0.0.1:16502/api/v1";
if (!/^http:\/\/(localhost|127\.0\.0\.1):\d+\/api\/v1$/.test(base)) {
  throw new Error("Reading record tests require an isolated localhost fixture");
}
const bookID = Number(process.env.IPAD_READING_RECORD_BOOK_ID ?? 1);
const fileID = Number(process.env.IPAD_READING_RECORD_FILE_ID ?? 1);
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
async function login(username = process.env.IPAD_READING_RECORD_USERNAME ?? "ipad-e04-record") {
  const response = await request("auth/login", {
    method: "POST",
    body: {
      username,
      password: "IpadFixture123",
      clientKind: "native",
      deviceLabel: "Reading record HTTP fixture",
    },
  });
  assert.equal(response.status, 200);
  return response.json();
}

test("IPAD-E04-A01-HTTP: cumulative native reading survives retries and committed deletion", async () => {
  const session = await login();
  const token = session.accessToken;
  const sessionId = randomUUID();
  const start = new Date(Date.now() - 660_000);
  const path = `books/files/${fileID}/sessions`;
  const initial = {
    sessionId,
    startedAt: start.toISOString(),
    endedAt: new Date(start.getTime() + 300_000).toISOString(),
    durationSeconds: 300,
    progressDelta: 5,
    endProgress: 15,
    sessionType: "read",
    source: "ios",
  };
  const before = await (await request(`books/${bookID}/sessions`, { token })).json();
  const save = async (body) => assert.equal((await request(path, { token, method: "POST", body })).status, 204);
  let row;
  try {
    await save(initial);
    await save(initial);
    const final = {
      ...initial,
      endedAt: new Date(start.getTime() + 600_000).toISOString(),
      durationSeconds: 600,
      progressDelta: 10,
      endProgress: 20,
    };
    await save(final);
    await save(final);
    const after = await (await request(`books/${bookID}/sessions`, { token })).json();
    assert.equal(after.stats.totalSeconds - before.stats.totalSeconds, 600);
    assert.equal(after.stats.totalSessions - before.stats.totalSessions, 1);
    row = after.items.find((item) => item.startedAt === start.toISOString());
    assert.ok(row);
    assert.equal(row.source, "ios");
    assert.equal(row.sessionType, "read");
    assert.equal(row.durationSeconds, 600);
    assert.equal(row.endProgress, 20);
    assert.equal((await request(`books/${bookID}/sessions/${row.id}`, { token, method: "DELETE" })).status, 204);
    await save({ ...final, durationSeconds: 610, endedAt: new Date(start.getTime() + 610_000).toISOString() });
    const deleted = await (await request(`books/${bookID}/sessions`, { token })).json();
    assert.equal(deleted.stats.totalSeconds, before.stats.totalSeconds);
    assert.equal(deleted.stats.totalSessions, before.stats.totalSessions);
    assert.ok(!deleted.items.some((item) => item.id === row.id || item.startedAt === start.toISOString()));
  } finally {
    if (row) await request(`books/${bookID}/sessions/${row.id}`, { token, method: "DELETE" });
    await request("auth/logout", { method: "POST", body: { refreshToken: session.refreshToken } });
  }
});

test("IPAD-E04-A01-HTTP: a manual session has retry-safe identity and does not change actual activity source", async () => {
  const session = await login();
  const token = session.accessToken;
  const path = `books/${bookID}/sessions`;
  const body = { clientId: randomUUID(), startedAt: new Date(Date.now() - 3_600_000).toISOString(), durationMinutes: 5, endProgress: 25 };
  let row;
  try {
    const first = await request(path, { token, method: "POST", body });
    assert.equal(first.status, 201);
    row = await first.json();
    const retry = await request(path, { token, method: "POST", body });
    assert.equal(retry.status, 201);
    assert.deepEqual(await retry.json(), row);
    assert.equal(row.source, "manual");
    assert.equal(row.durationSeconds, 300);
    const list = await (await request(path, { token })).json();
    assert.equal(list.items.filter((item) => item.id === row.id).length, 1);
  } finally {
    if (row) await request(`${path}/${row.id}`, { token, method: "DELETE" });
    await request("auth/logout", { method: "POST", body: { refreshToken: session.refreshToken } });
  }
});
