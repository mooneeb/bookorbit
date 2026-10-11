import { test } from "node:test";
import assert from "node:assert/strict";

const base = process.env.IPAD_E04_API_URL ?? "http://127.0.0.1:16502/api/v1";
const receiver = process.env.IPAD_E04_RECEIVER_URL;
if (!/^http:\/\/(localhost|127\.0\.0\.1):\d+\/api\/v1$/.test(base)) {
  throw new Error("Hardcover tests require the isolated localhost HTTP fixture");
}
const bookID = Number(process.env.IPAD_E04_HARDCOVER_BOOK_ID ?? 1);

async function request(path, token, method = "GET", body) {
  return fetch(`${base}/${path}`, {
    method,
    signal: AbortSignal.timeout(60_000),
    headers: { ...(token ? { Authorization: `Bearer ${token}` } : {}), ...(body ? { "Content-Type": "application/json" } : {}) },
    ...(body ? { body: JSON.stringify(body) } : {}),
  });
}
async function json(path, token, method = "GET", body, expected = path === "books/bulk-set-rating" ? 204 : method === "POST" ? 201 : 200) {
  const response = await request(path, token, method, body);
  assert.equal(response.status, expected, `${method} ${path}: ${await response.clone().text()}`);
  return response.status === 204 ? {} : response.json();
}
async function login(username) {
  return json(
    "auth/login",
    null,
    "POST",
    { username, password: "IpadFixture123", clientKind: "native", deviceLabel: "Hardcover HTTP acceptance" },
    200,
  );
}
async function control(mode, operation, count) {
  assert.ok(receiver, "IPAD_E04_RECEIVER_URL must identify the controlled provider");
  const response = await fetch(`${receiver}/control`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ provider: "hardcover", mode, ...(operation ? { operation } : {}), ...(count ? { count } : {}) }),
  });
  assert.equal(response.status, 204);
}
async function receipts() {
  const response = await fetch(`${receiver}/receipts?provider=hardcover&limit=100`);
  assert.equal(response.status, 200);
  return response.json();
}
async function waitOutcome(token, runID) {
  const deadline = Date.now() + 60_000;
  let outcome;
  do {
    outcome = await json("hardcover/sync/outcome", token);
    if (outcome?.runId === runID && outcome.status !== "running") return outcome;
    await new Promise((resolve) => setTimeout(resolve, 200));
  } while (Date.now() < deadline);
  assert.fail(`Hardcover job did not finish: ${JSON.stringify(outcome)}`);
}

test("IPAD-E04-A05-HC-HTTP: eligible reading records, mapping and verified provider outcomes", { timeout: 180_000 }, async (t) => {
  const owner = await login("ipad-owner");
  const other = await login("ipad-reader");
  const restricted = await login("ipad-restricted");
  const token = owner.accessToken;
  const detail = await json(`books/${bookID}`, token);
  const oldNote = detail.personalNote;
  try {
    await control("accept");
    await t.test("IPAD-E04-A05-HC-SETTINGS-permission-credential-isolation", async () => {
      assert.equal((await request("hardcover/settings")).status, 401);
      assert.equal((await request("hardcover/settings", restricted.accessToken)).status, 403);
      assert.equal((await request("hardcover/sync", restricted.accessToken, "POST")).status, 403);
      assert.equal((await request("hardcover/settings", token, "PATCH", { apiToken: "fixture-hardcover", unexpected: true })).status, 400);
      const verified = await json("hardcover/validate-token", token, "POST", { token: "fixture-hardcover" });
      assert.equal(verified.valid, true);
      assert.equal(verified.hardcoverUsername, "fixture-hardcover");
      const saved = await json("hardcover/settings", token, "PATCH", {
        apiToken: "fixture-hardcover",
        enabled: true,
        bookSyncMode: "selected_only",
        privacySettingId: 3,
        autoSyncOnStatusChange: false,
        autoSyncOnProgressUpdate: false,
        autoSyncOnRatingChange: false,
      });
      assert.equal(saved.tokenConfigured, true);
      assert.equal(saved.effectiveEnabled, true);
      assert.equal(Object.hasOwn(saved, "apiToken"), false);
      const isolated = await request("hardcover/settings", other.accessToken);
      assert.ok([200, 403].includes(isolated.status));
      if (isolated.status === 200) assert.equal((await isolated.json()).tokenConfigured, false);
    });
    await t.test("IPAD-E04-A05-HC-SCOPE-own-selected-record-and-private-note-excluded", async () => {
      await json(`books/${bookID}/status`, token, "PATCH", { status: "reading", startedAt: "2026-10-10" });
      await json(`books/${bookID}/personal-note`, token, "PATCH", { note: "HARDCOVER_PRIVATE_NOTE_MUST_NOT_TRANSFER" });
      const file = detail.files.find((value) => value.id === detail.primaryFileId) ?? detail.files[0];
      assert.ok(file);
      assert.equal((await request(`books/files/${file.id}/progress`, token, "POST", { percentage: 20 })).status, 201);
      await json(`hardcover/books/${bookID}/sync-state`, token, "PATCH", { syncEnabled: true });
      let result = await json(`hardcover/books/${bookID}/sync`, token, "POST");
      assert.ok(["synced", "skipped"].includes(result.result));
      assert.ok(result.state.lastSyncedAt);
      assert.equal(result.state.syncError, null);
      const evidence = await receipts();
      const book = evidence.hardcover.userBooks.find((value) => value.book_id === 101);
      assert.ok(book);
      assert.equal(book.status_id, 2);
      assert.equal(book.privacy_setting_id, 3);
      const reads = evidence.hardcover.reads.filter((value) => value.user_book_id === book.id);
      assert.ok(reads.length >= 1);
      assert.equal(reads.find((value) => value.started_at === "2026-10-10")?.progress_pages, 20);
      assert.equal(JSON.stringify(evidence).includes("HARDCOVER_PRIVATE_NOTE_MUST_NOT_TRANSFER"), false);
      const before = evidence.hardcover.totalReads;
      result = await json(`hardcover/books/${bookID}/sync`, token, "POST");
      assert.equal(result.result, "skipped");
      assert.equal((await receipts()).hardcover.totalReads, before);
      const editions = await json(`hardcover/books/${bookID}/editions`, token);
      assert.ok(editions.editions.some((value) => value.id === 501));
      assert.deepEqual(await json(`hardcover/books/${bookID}/edition`, token, "PATCH", { editionId: 501 }), { success: true });
      assert.equal((await request(`hardcover/books/${bookID}/edition`, token, "PATCH", { editionId: 999999 })).status, 400);
    });
    await t.test("IPAD-E04-A05-HC-FAILURE-verified-receipt-auth-timeout-rate-retry", async () => {
      let attempt = 0;
      for (const mode of ["malformed", "auth", "500", "timeout-after-receipt"]) {
        await json("books/bulk-set-rating", token, "POST", { bookIds: [bookID], rating: ++attempt });
        await control(mode, "UpdateUserBook");
        const failed = await json(`hardcover/books/${bookID}/sync`, token, "POST");
        assert.equal(failed.result, "failed", mode);
        assert.ok(failed.state.syncError, mode);
        const before = (await receipts()).hardcover.totalReads;
        await control("accept");
        const retry = await json(`hardcover/books/${bookID}/sync`, token, "POST");
        assert.equal(retry.result, "synced", mode);
        assert.equal(retry.state.syncError, null);
        assert.equal((await receipts()).hardcover.totalReads, before);
      }
      await json("books/bulk-set-rating", token, "POST", { bookIds: [bookID], rating: 5 });
      await control("429", "UpdateUserBook", 1);
      assert.equal((await json(`hardcover/books/${bookID}/sync`, token, "POST")).result, "synced");
      await control("accept");
      const started = await json("hardcover/sync", token, "POST");
      const completed = await waitOutcome(token, started.runId);
      assert.equal(completed.status, "completed");
      assert.equal(completed.processedBooks, completed.syncedBooks + completed.skippedBooks + completed.failedBooks);
      assert.ok(completed.finishedAt);
      assert.deepEqual(await json("hardcover/sync/outcome", token), completed);
    });
  } finally {
    await control("accept");
    await request("hardcover/settings", token, "PATCH", { enabled: false });
    await request(`books/${bookID}/personal-note`, token, "PATCH", { note: oldNote ?? null });
    for (const session of [owner, other, restricted]) await request("auth/logout", null, "POST", { refreshToken: session.refreshToken });
  }
});
