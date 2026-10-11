import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { test } from "node:test";

const base = process.env.IPAD_E04_API_URL ?? "http://127.0.0.1:16502/api/v1";
if (!/^http:\/\/(localhost|127\.0\.0\.1):\d+\/api\/v1$/.test(base)) {
  throw new Error("Session attribution tests require an isolated localhost fixture");
}
const bookID = Number(process.env.IPAD_SESSION_ATTRIBUTION_BOOK_ID ?? 1);
const fileID = Number(process.env.IPAD_SESSION_ATTRIBUTION_FILE_ID ?? 1);
const otherBookID = Number(process.env.IPAD_SESSION_ATTRIBUTION_OTHER_BOOK_ID ?? 3);
const password = "IpadFixture123";

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

async function json(path, options) {
  const response = await request(path, options);
  assert.ok(response.ok, `${path}: ${response.status} ${await response.clone().text()}`);
  return response.json();
}

async function login(username) {
  return json("auth/login", {
    method: "POST",
    body: { username, password, clientKind: "native", deviceLabel: "E04 session attribution HTTP" },
  });
}

async function createReader(ownerToken, libraryIds) {
  const username = `e04-attribution-${randomUUID().slice(0, 8)}`;
  const user = await json("users", {
    token: ownerToken,
    method: "POST",
    body: {
      username,
      name: username,
      email: `${username}@example.test`,
      permissionNames: ["library_download", "annotation_manage_own"],
      libraryIds,
    },
  });
  const response = await request("auth/reset-password", {
    method: "POST",
    body: { token: new URL(user.resetUrl).searchParams.get("token"), newPassword: password },
  });
  assert.equal(response.status, 204);
  return { user, session: await login(username) };
}

test("IPAD-E04-A01-ATTEMPT-ATTRIBUTION: captured offline sessions keep historical attempts, unknown stays unassigned, and legacy clients retain save-time behavior", async () => {
  const owner = await login("ipad-owner");
  const readers = [];
  try {
    const book = await json(`books/${bookID}`, { token: owner.accessToken });
    const otherBook = await json(`books/${otherBookID}`, { token: owner.accessToken });
    const libraries = [...new Set([book.libraryId, otherBook.libraryId])];
    const reader = await createReader(owner.accessToken, libraries);
    readers.push(reader);
    const otherReader = await createReader(owner.accessToken, libraries);
    readers.push(otherReader);
    const token = reader.session.accessToken;
    const contextPath = `books/files/${fileID}/session-context`;
    const sessionsPath = `books/files/${fileID}/sessions`;
    const attemptsPath = `books/${bookID}/reading-attempts`;
    assert.deepEqual(await json(contextPath, { token }), { bookId: bookID, attemptId: null });

    let response = await request(`books/${bookID}/status`, { token, method: "PATCH", body: { status: "reading" } });
    assert.equal(response.status, 200);
    const attemptA = (await json(contextPath, { token })).attemptId;
    assert.ok(Number.isInteger(attemptA) && attemptA > 0);
    response = await request(`books/${bookID}/status`, { token, method: "PATCH", body: { status: "read" } });
    assert.equal(response.status, 200);
    response = await request(`${attemptsPath}/start-reread`, { token, method: "POST", body: { resetProgress: false } });
    assert.equal(response.status, 201);
    const attemptB = (await json(contextPath, { token })).attemptId;
    assert.ok(Number.isInteger(attemptB) && attemptB > 0);
    assert.notEqual(attemptB, attemptA);

    const startedAt = new Date(Date.now() - 300_000);
    const activity = (offsetSeconds = 0) => ({
      sessionId: randomUUID(),
      startedAt: new Date(startedAt.getTime() + offsetSeconds * 1000).toISOString(),
      endedAt: new Date(startedAt.getTime() + (offsetSeconds + 60) * 1000).toISOString(),
      durationSeconds: 60,
      sessionType: "read",
      source: "ios",
    });
    const captured = { ...activity(), attemptId: attemptA };
    const unknown = { ...activity(90), attemptId: null };
    const legacy = activity(180);
    for (const body of [captured, unknown, legacy, captured]) {
      assert.equal((await request(sessionsPath, { token, method: "POST", body })).status, 204);
    }
    const sessions = await json(`books/${bookID}/sessions?pageSize=100`, { token });
    const find = (body) => sessions.items.find((row) => row.startedAt === body.startedAt);
    assert.equal(find(captured)?.attemptId, attemptA);
    assert.equal(find(unknown)?.attemptId, null);
    assert.equal(find(legacy)?.attemptId, attemptB);
    assert.equal(sessions.items.length, 3);
    assert.equal(sessions.stats.totalSeconds, 180);
    const history = await json(`${attemptsPath}?pageSize=100`, { token });
    assert.equal(history.items.find((row) => row.id === attemptA)?.totalSessions, 1);
    assert.equal(history.items.find((row) => row.id === attemptB)?.totalSessions, 1);

    const foreignBookAttempt = await json(`books/${otherBookID}/reading-attempts`, {
      token,
      method: "POST",
      body: { outcome: "completed" },
    });
    const foreignUserAttempt = await json(attemptsPath, {
      token: otherReader.session.accessToken,
      method: "POST",
      body: { outcome: "completed" },
    });
    for (const attemptId of [foreignBookAttempt.id, foreignUserAttempt.id]) {
      assert.equal((await request(sessionsPath, { token, method: "POST", body: { ...activity(), attemptId } })).status, 403);
    }
    assert.equal(
      (await request(sessionsPath, { token, method: "POST", body: { ...captured, attemptId: attemptB, durationSeconds: 61 } })).status,
      400,
    );
    assert.equal((await request(sessionsPath, { token, method: "POST", body: { ...activity(), attemptId: 0 } })).status, 400);
    const afterRejected = await json(`books/${bookID}/sessions?pageSize=100`, { token });
    assert.deepEqual(afterRejected, sessions);
  } finally {
    for (const reader of readers) {
      await request("auth/logout", { method: "POST", body: { refreshToken: reader.session.refreshToken } });
      assert.equal((await request(`users/${reader.user.id}`, { token: owner.accessToken, method: "DELETE" })).status, 204);
    }
    await request("auth/logout", { method: "POST", body: { refreshToken: owner.refreshToken } });
  }
});
