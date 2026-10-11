import { test } from "node:test";
import assert from "node:assert/strict";
import { createHash, randomUUID } from "node:crypto";

const base = process.env.IPAD_E04_API_URL ?? "http://127.0.0.1:16502/api/v1";
const receiver = process.env.IPAD_E04_RECEIVER_URL;
if (!/^http:\/\/(localhost|127\.0\.0\.1):\d+\/api\/v1$/.test(base)) {
  throw new Error("Hardcover tests require the isolated localhost HTTP fixture");
}
if (!/^http:\/\/(localhost|127\.0\.0\.1):\d+$/.test(receiver ?? "")) {
  throw new Error("Hardcover search tests require the controlled localhost provider");
}
const bookID = Number(process.env.IPAD_E04_HARDCOVER_SEARCH_BOOK_ID ?? 2);
assert.ok(Number.isSafeInteger(bookID) && bookID > 0);
const password = "IpadFixture123";

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
  assert.equal(response.status, expected, `${method} ${path} returned an unexpected status`);
  return response.status === 204 ? {} : response.json();
}
async function login(username) {
  return json("auth/login", null, "POST", { username, password, clientKind: "native", deviceLabel: "Hardcover HTTP acceptance" }, 200);
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
async function receipts(namespace) {
  const evidence = { userBooks: [], reads: [] };
  let total = 0;
  for (let offset = 0; offset === 0 || offset < total; offset += 100) {
    const response = await fetch(`${receiver}/receipts?provider=hardcover&limit=100&offset=${offset}`, { signal: AbortSignal.timeout(10_000) });
    assert.equal(response.status, 200);
    const page = (await response.json()).hardcover;
    total = Math.max(page.totalUserBooks, page.totalReads);
    assert.ok(Number.isSafeInteger(total) && total <= 10_000, "Controlled provider evidence must remain bounded");
    evidence.userBooks.push(...page.userBooks.filter((book) => book.namespace === namespace));
    evidence.reads.push(...page.reads.filter((read) => read.namespace === namespace));
  }
  return evidence;
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

test("IPAD-E04-A05-HC-SEARCH-HTTP: payload failure persists failed job and retry verifies one record", { timeout: 120_000 }, async () => {
  const owner = await login("ipad-owner");
  const providerToken = `fixture-search-${randomUUID()}`;
  const namespace = createHash("sha256").update(`Bearer ${providerToken}`).digest("hex").slice(0, 12);
  let detail;
  let account;
  let session;
  let metadataChanged = false;
  let scenarioError;
  const cleanupFailures = [];
  const cleanup = async (name, action) => {
    try {
      await action();
    } catch {
      cleanupFailures.push(name);
    }
  };
  try {
    detail = await json(`books/${bookID}`, owner.accessToken);
    assert.ok(Number.isSafeInteger(detail.libraryId));
    const username = `e04-hc-search-${randomUUID().slice(0, 8)}`;
    account = await json("users", owner.accessToken, "POST", {
      username,
      name: username,
      email: `${username}@example.test`,
      permissionNames: ["hardcover_sync"],
      libraryIds: [detail.libraryId],
    });
    const resetToken = new URL(account.resetUrl).searchParams.get("token");
    assert.ok(resetToken);
    await json("auth/reset-password", null, "POST", { token: resetToken, newPassword: password }, 204);
    session = await login(username);
    const token = session.accessToken;
    const me = await json("auth/me", token);
    assert.equal(me.isSuperuser, false);
    assert.deepEqual(me.permissions, ["hardcover_sync"]);
    assert.equal((await json(`books/${bookID}`, token)).readStatus, null, "Disposable user must have no inherited reading status");
    const initial = await json(`hardcover/books/${bookID}/sync-state`, token);
    assert.equal(initial.lastSyncedAt, null, "Disposable user must have no cached mapping");
    assert.equal(initial.syncError, null);
    await control("accept");
    await json("hardcover/settings", token, "PATCH", {
      apiToken: providerToken,
      enabled: true,
      bookSyncMode: "all_eligible",
      autoSyncOnStatusChange: false,
      autoSyncOnProgressUpdate: false,
      autoSyncOnRatingChange: false,
    });
    metadataChanged = true;
    await json(`books/${bookID}/metadata`, owner.accessToken, "PATCH", {
      authors: ["E04 Search Author"],
      hardcoverId: null,
      hardcoverEditionId: null,
      isbn10: null,
      isbn13: null,
    });
    await json(`books/${bookID}/status`, token, "PATCH", { status: "reading", startedAt: "2026-10-10" });
    assert.deepEqual(await json("hardcover/sync/pending", token), { totalBooks: 1, pendingBooks: 1 });
    assert.equal((await receipts(namespace)).userBooks.length, 0);
    await control("search-error", "SearchBooks");
    const started = await json("hardcover/sync", token, "POST");
    const failed = await waitOutcome(token, started.runId);
    assert.equal(failed.status, "failed");
    assert.equal(failed.totalBooks, 1);
    assert.equal(failed.processedBooks, 1);
    assert.equal(failed.failedBooks, 1);
    assert.equal(failed.syncedBooks, 0);
    assert.equal(failed.skippedBooks, 0);
    assert.ok(failed.error);
    assert.deepEqual(await json("hardcover/sync/outcome", token), failed);
    const state = await json(`hardcover/books/${bookID}/sync-state`, token);
    assert.equal(state.syncError, "Hardcover search failed. Retry after checking the connection.");
    assert.equal(state.lastSyncedAt, null);
    const failedEvidence = await receipts(namespace);
    assert.equal(failedEvidence.userBooks.length, 0);
    assert.equal(failedEvidence.reads.length, 0);

    await control("accept");
    const retry = await json("hardcover/sync", token, "POST");
    const recovered = await waitOutcome(token, retry.runId);
    assert.equal(recovered.status, "completed");
    assert.equal(recovered.totalBooks, 1);
    assert.equal(recovered.processedBooks, 1);
    assert.equal(recovered.syncedBooks, 1);
    assert.equal(recovered.failedBooks, 0);
    assert.equal(recovered.skippedBooks, 0);
    assert.equal(recovered.error, null);
    assert.deepEqual(await json("hardcover/sync/outcome", token), recovered);
    const resolved = await json(`hardcover/books/${bookID}/sync-state`, token);
    assert.equal(resolved.syncError, null);
    assert.ok(resolved.lastSyncedAt);
    const evidence = await receipts(namespace);
    assert.equal(evidence.userBooks.length, 1);
    assert.equal(evidence.userBooks[0].book_id, 102);
    assert.equal(evidence.reads.length, 1);
    assert.equal(evidence.reads[0].user_book_id, evidence.userBooks[0].id);
    assert.equal((await json(`hardcover/books/${bookID}/sync`, token, "POST")).result, "skipped");
    const repeated = await receipts(namespace);
    assert.equal(repeated.userBooks.length, 1);
    assert.equal(repeated.reads.length, 1);
  } catch (error) {
    scenarioError = error;
  } finally {
    await cleanup("provider accept", () => control("accept"));
    if (session) {
      await cleanup("disable integration", () => json("hardcover/settings", session.accessToken, "PATCH", { enabled: false }));
      await cleanup("disposable user logout", () => json("auth/logout", null, "POST", { refreshToken: session.refreshToken }, 200));
    }
    if (metadataChanged) {
      await cleanup("restore shared metadata", () =>
        json(`books/${bookID}/metadata`, owner.accessToken, "PATCH", {
          authors: detail.authors.map((author) => author.name),
          hardcoverId: detail.providerIds.hardcover ?? null,
          hardcoverEditionId: detail.hardcoverEditionId ?? null,
          isbn10: detail.isbn10 ?? null,
          isbn13: detail.isbn13 ?? null,
        }),
      );
    }
    if (account) await cleanup("delete disposable user", () => json(`users/${account.id}`, owner.accessToken, "DELETE", undefined, 204));
    await cleanup("owner logout", () => json("auth/logout", null, "POST", { refreshToken: owner.refreshToken }, 200));
  }
  if (cleanupFailures.length)
    throw new AggregateError([...(scenarioError ? [scenarioError] : []), new Error(`Cleanup failed: ${cleanupFailures.join(", ")}`)]);
  if (scenarioError) throw scenarioError;
});
