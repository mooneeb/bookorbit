import { test } from "node:test";
import assert from "node:assert/strict";

const base = process.env.IPAD_E04_API_URL ?? "http://127.0.0.1:16502/api/v1";
if (!/^http:\/\/(localhost|127\.0\.0\.1):\d+\/api\/v1$/.test(base)) throw new Error("Personal record tests require an isolated localhost fixture");
const bookID = Number(process.env.IPAD_PERSONAL_RECORD_BOOK_ID ?? 3);

async function request(path, { token, method = "GET", body } = {}) {
  return fetch(`${base}/${path}`, {
    method,
    headers: { ...(token ? { Authorization: `Bearer ${token}` } : {}), ...(body ? { "Content-Type": "application/json" } : {}) },
    ...(body ? { body: JSON.stringify(body) } : {}),
  });
}

async function login(clientKind = "native") {
  const response = await request("auth/login", {
    method: "POST",
    body: {
      username: process.env.IPAD_PERSONAL_RECORD_USERNAME ?? "ipad-e04-record",
      password: "IpadFixture123",
      clientKind,
      deviceLabel: "Personal record concurrency fixture",
    },
  });
  assert.equal(response.status, 200);
  return response.json();
}

function calendarDate(value) {
  if (typeof value !== "string") return value;
  const match = /^(\d{4}-\d{2}-\d{2})T00:00:00(?:\.0+)?Z$/.exec(value);
  if (!match) return value;
  const date = new Date(value);
  if (Number.isNaN(date.getTime()) || date.toISOString().slice(0, 10) !== match[1]) return value;
  return match[1];
}

function statusWithCalendarDates(status) {
  return { ...status, startedAt: calendarDate(status.startedAt), finishedAt: calendarDate(status.finishedAt) };
}

test("IPAD-E04-A01-CONFLICT-NOTE: stale offline note preserves the web note", async () => {
  const session = await login();
  const web = await login("web");
  const token = session.accessToken;
  const path = `books/${bookID}/personal-note`;
  const original = await (await request(`books/${bookID}`, { token })).json();
  try {
    assert.equal((await request(path, { token, method: "PATCH", body: { note: "Offline base note" } })).status, 200);
    assert.equal((await request(path, { token: web.accessToken, method: "PATCH", body: { note: "Current web note" } })).status, 200);
    const stale = await request(path, { token, method: "PATCH", body: { note: "Offline recovery note", baseNote: "Offline base note" } });
    assert.equal(stale.status, 409);
    const conflict = await stale.json();
    assert.equal(conflict.errorCode, "PERSONAL_RECORD_CONFLICT");
    assert.equal(conflict.field, "note");
    assert.equal(conflict.current, "Current web note");
    assert.equal((await (await request(`books/${bookID}`, { token })).json()).personalNote, "Current web note");
  } finally {
    await request(path, { token, method: "PATCH", body: { note: original.personalNote } });
    await request("auth/logout", { method: "POST", body: { refreshToken: session.refreshToken } });
    await request("auth/logout", { method: "POST", body: { refreshToken: web.refreshToken } });
  }
});

test("IPAD-E04-A01-CONFLICT-RATING-STATUS: stale writes preserve the web rating, status and history", async () => {
  const session = await login();
  const web = await login("web");
  const token = session.accessToken;
  const original = await (await request(`books/${bookID}`, { token })).json();
  const attemptsPath = `books/${bookID}/reading-attempts?page=1&pageSize=100`;
  const initialHistory = await (await request(attemptsPath, { token })).json();
  try {
    assert.equal((await request(`books/${bookID}/rating`, { token, method: "PATCH", body: { rating: 1 } })).status, 200);
    assert.equal((await request(`books/${bookID}/metadata`, { token: web.accessToken, method: "PATCH", body: { rating: 4 } })).status, 200);
    const staleRating = await request(`books/${bookID}/rating`, { token, method: "PATCH", body: { rating: 2, baseRating: 1 } });
    assert.equal(staleRating.status, 409);
    assert.equal((await staleRating.json()).current, 4);
    assert.equal((await (await request(`books/${bookID}`, { token })).json()).rating, 4);

    const baselineResponse = await request(`books/${bookID}/status`, { token, method: "PATCH", body: { status: "reading" } });
    assert.equal(baselineResponse.status, 200);
    const baseline = await baselineResponse.json();
    const currentResponse = await request(`books/${bookID}/status`, { token: web.accessToken, method: "PATCH", body: { status: "read" } });
    assert.equal(currentResponse.status, 200);
    const current = await currentResponse.json();
    const currentHistory = await (await request(attemptsPath, { token })).json();
    const staleStatus = await request(`books/${bookID}/status`, {
      token,
      method: "PATCH",
      body: { status: "abandoned", baseStatusUpdatedAt: baseline.updatedAt },
    });
    assert.equal(staleStatus.status, 409);
    const conflict = await staleStatus.json();
    assert.equal(conflict.errorCode, "PERSONAL_RECORD_CONFLICT");
    assert.equal(conflict.field, "status");
    assert.deepEqual(conflict.current, current);
    const bookStatus = (await (await request(`books/${bookID}`, { token })).json()).readStatus;
    assert.deepEqual(statusWithCalendarDates(bookStatus), statusWithCalendarDates(current));
    assert.deepEqual(await (await request(attemptsPath, { token })).json(), currentHistory);
  } finally {
    const history = await (await request(attemptsPath, { token })).json();
    const initialIDs = new Set(initialHistory.items.map((item) => item.id));
    for (const item of history.items) {
      if (!initialIDs.has(item.id)) await request(`books/${bookID}/reading-attempts/${item.id}`, { token, method: "DELETE" });
    }
    await request(`books/${bookID}/rating`, { token, method: "PATCH", body: { rating: original.rating } });
    await request(`books/${bookID}/status`, { token, method: "PATCH", body: { status: original.readStatus?.status ?? "unread" } });
    for (const userSession of [session, web]) await request("auth/logout", { method: "POST", body: { refreshToken: userSession.refreshToken } });
  }
});

test("IPAD-E04-A01-CONDITIONAL-COMPATIBILITY: matching conditional writes and legacy web writes succeed", async () => {
  const session = await login();
  const token = session.accessToken;
  const original = await (await request(`books/${bookID}`, { token })).json();
  try {
    let result = await request(`books/${bookID}/personal-note`, { token, method: "PATCH", body: { note: null } });
    assert.equal(result.status, 200);
    result = await request(`books/${bookID}/personal-note`, { token, method: "PATCH", body: { note: "Matched offline note", baseNote: null } });
    assert.equal(result.status, 200);
    assert.equal((await result.json()).personalNote, "Matched offline note");
    result = await request(`books/${bookID}/personal-note`, {
      token,
      method: "PATCH",
      body: { note: "Second matched note", baseNote: "Matched offline note" },
    });
    assert.equal(result.status, 200);
    assert.equal((await result.json()).personalNote, "Second matched note");
    result = await request(`books/${bookID}/personal-note`, { token, method: "PATCH", body: { note: "Legacy web note" } });
    assert.equal(result.status, 200);
    assert.equal((await result.json()).personalNote, "Legacy web note");
    const noteRace = await Promise.all(
      ["First concurrent note", "Second concurrent note"].map((note) =>
        request(`books/${bookID}/personal-note`, { token, method: "PATCH", body: { note, baseNote: "Legacy web note" } }),
      ),
    );
    assert.deepEqual(noteRace.map((response) => response.status).sort(), [200, 409]);
    assert.equal((await request(`books/${bookID}/rating`, { token, method: "PATCH", body: { rating: null } })).status, 200);
    result = await request(`books/${bookID}/rating`, { token, method: "PATCH", body: { rating: 3, baseRating: null } });
    assert.equal(result.status, 200);
    assert.equal((await result.json()).rating, 3);
    const ratingRace = await Promise.all(
      [2, 4].map((rating) => request(`books/${bookID}/rating`, { token, method: "PATCH", body: { rating, baseRating: 3 } })),
    );
    assert.deepEqual(ratingRace.map((response) => response.status).sort(), [200, 409]);
    assert.equal((await request(`books/${bookID}/metadata`, { token, method: "PATCH", body: { rating: 5 } })).status, 200);
    assert.equal((await (await request(`books/${bookID}`, { token })).json()).rating, 5);
    result = await request(`books/${bookID}/status`, { token, method: "PATCH", body: { status: "want_to_read" } });
    assert.equal(result.status, 200);
    const baseline = await result.json();
    result = await request(`books/${bookID}/status`, { token, method: "PATCH", body: { status: "unread", baseStatusUpdatedAt: baseline.updatedAt } });
    assert.equal(result.status, 200);
    assert.equal((await result.json()).status, "unread");
    const current = await (await request(`books/${bookID}`, { token })).json();
    const statusRace = await Promise.all(
      ["unread", "want_to_read"].map((status) =>
        request(`books/${bookID}/status`, { token, method: "PATCH", body: { status, baseStatusUpdatedAt: current.readStatus.updatedAt } }),
      ),
    );
    assert.deepEqual(statusRace.map((response) => response.status).sort(), [200, 409]);
  } finally {
    await request(`books/${bookID}/personal-note`, { token, method: "PATCH", body: { note: original.personalNote } });
    await request(`books/${bookID}/rating`, { token, method: "PATCH", body: { rating: original.rating } });
    await request(`books/${bookID}/status`, { token, method: "PATCH", body: { status: original.readStatus?.status ?? "unread" } });
    await request("auth/logout", { method: "POST", body: { refreshToken: session.refreshToken } });
  }
});
