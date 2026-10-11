import { test } from "node:test";
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";

const base = process.env.IPAD_E04_API_URL ?? "http://127.0.0.1:16502/api/v1";
const receiver = process.env.IPAD_E04_RECEIVER_URL;
const bookID = Number(process.env.IPAD_E04_IMPORT_BOOK_ID ?? 1);
if (!/^http:\/\/(localhost|127\.0\.0\.1):\d+\/api\/v1$/.test(base)) throw new Error("Import acceptance requires the isolated localhost server");

async function request(path, token, method = "GET", body) {
  return fetch(`${base}/${path}`, {
    method,
    headers: {
      ...(token ? { Authorization: `Bearer ${token}` } : {}),
      ...(body ? { "Content-Type": "application/json" } : {}),
    },
    ...(body ? { body: JSON.stringify(body) } : {}),
  });
}
async function json(path, token, method = "GET", body, status = method === "POST" ? 201 : 200) {
  const response = await request(path, token, method, body);
  assert.equal(response.status, status, `${method} ${path}: ${await response.clone().text()}`);
  return response.json();
}
async function external(path, body) {
  assert.ok(receiver, "IPAD_E04_RECEIVER_URL must identify the controlled Hardcover receiver");
  const response = await fetch(`${receiver}/${path}`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
  assert.ok(response.ok, `${path}: ${await response.text()}`);
}
async function login(username) {
  return json(
    "auth/login",
    null,
    "POST",
    { username, password: "IpadFixture123", clientKind: "native", deviceLabel: "Hardcover import HTTP acceptance" },
    200,
  );
}

test("IPAD-E04-QA5-HCI-HTTP: bounded real import preview, apply, persistence, retry and provider failure", async (t) => {
  const owner = await login(process.env.IPAD_E04_IMPORT_USERNAME ?? "ipad-reader");
  const restricted = await login("ipad-restricted");
  const token = owner.accessToken;
  const providerToken = `fixture-import-${randomUUID()}`;
  const before = await json(`books/${bookID}`, token);
  const beforeStatus = before.readStatus;
  let importedAttempt;
  try {
    await external("control", { provider: "hardcover", mode: "accept" });
    await json("hardcover/settings", token, "PATCH", {
      apiToken: providerToken,
      enabled: true,
      bookSyncMode: "selected_only",
      autoSyncOnStatusChange: false,
    });
    await json(`books/${bookID}/status`, token, "PATCH", { status: "unread" });
    const providerID = Number(process.env.IPAD_E04_IMPORT_HARDCOVER_ID ?? 101);
    const userBooks = Array.from({ length: 101 }, (_, index) => ({
      id: 50000 + index,
      book_id: index === 0 ? providerID : 60000 + index,
      edition_id: 501,
      status_id: 3,
    }));
    await external("fixtures", {
      provider: "hardcover",
      token: providerToken,
      userBooks,
      reads: [
        {
          id: 59001,
          user_book_id: 50000,
          started_at: "2026-09-01",
          finished_at: "2026-09-03",
          progress: 100,
          progress_pages: 100,
          progress_seconds: null,
        },
      ],
    });
    await t.test("IPAD-E04-QA5-HCI01-HTTP-contract-permission-and-cursor", async () => {
      assert.equal((await request("hardcover/import/preview", null, "POST", {})).status, 401);
      assert.equal((await request("hardcover/import/apply", restricted.accessToken, "POST", {})).status, 403);
      assert.equal((await request("hardcover/import/preview", token, "POST", { afterId: -1 })).status, 400);
      assert.equal(
        (await request("hardcover/import/apply", token, "POST", { hardcoverUserBookIds: Array.from({ length: 101 }, (_, i) => i + 1) })).status,
        400,
      );
      assert.equal((await request("hardcover/import/apply", token, "POST", { unexpected: true })).status, 400);
      const page = await json("hardcover/import/preview", token, "POST", {});
      assert.equal(page.rows.length, 100);
      assert.equal(page.summary.totalHardcoverBooks, 100);
      assert.equal(page.nextCursor, 50099);
      assert.equal(page.truncated, true);
      assert.equal(page.limit, 100);
      assert.equal(page.rows[0].localBookId, bookID);
      assert.equal(page.rows[0].outcome, "will_update");
      const second = await json("hardcover/import/preview", token, "POST", { afterId: page.nextCursor });
      assert.equal(second.rows.length, 1);
      assert.equal(second.rows[0].hardcoverUserBookId, 50100);
      assert.equal(second.nextCursor, null);
      assert.equal(second.truncated, false);
    });
    await t.test("IPAD-E04-QA5-HCI02-HTTP-apply-retry-and-owned-history", async () => {
      const result = await json("hardcover/import/apply", token, "POST", { hardcoverUserBookIds: [50000], importProgress: false });
      assert.equal(result.applied, 1);
      assert.equal(result.failed, 0);
      assert.equal(result.progressApplied, 0);
      const book = await json(`books/${bookID}`, token);
      assert.equal(book.readStatus.status, "read");
      const history = await json(`books/${bookID}/reading-attempts?pageSize=100`, token);
      importedAttempt = history.items.find((attempt) => attempt.externalProvider === "hardcover" && attempt.externalId === "59001");
      assert.ok(importedAttempt, "Public reading history contains the imported external reading attempt");
      const again = await json("hardcover/import/apply", token, "POST", { hardcoverUserBookIds: [50000] });
      assert.equal(again.applied, 0);
      assert.equal(again.conflicts, 1);
      const after = await json(`books/${bookID}/reading-attempts?pageSize=100`, token);
      assert.equal(after.items.filter((attempt) => attempt.externalProvider === "hardcover" && attempt.externalId === "59001").length, 1);
    });
    await t.test("IPAD-E04-QA5-HCI03-HTTP-provider-failure-does-not-report-success", async () => {
      await external("control", { provider: "hardcover", mode: "auth", count: 1 });
      assert.equal((await request("hardcover/import/apply", token, "POST", { hardcoverUserBookIds: [50000] })).status, 400);
      await external("control", { provider: "hardcover", mode: "accept" });
      assert.equal((await json("hardcover/import/preview", token, "POST", {})).rows[0].outcome, "conflict");
    });
  } finally {
    if (importedAttempt) await request(`books/${bookID}/reading-attempts/${importedAttempt.id}`, token, "DELETE");
    await request(`books/${bookID}/status`, token, "PATCH", {
      status: beforeStatus?.status ?? "unread",
      startedAt: beforeStatus?.startedAt ?? null,
      finishedAt: beforeStatus?.finishedAt ?? null,
    });
    await request("hardcover/settings", token, "DELETE");
    for (const session of [owner, restricted]) await request("auth/logout", null, "POST", { refreshToken: session.refreshToken });
  }
});
