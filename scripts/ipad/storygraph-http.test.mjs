import assert from "node:assert/strict";
import { test } from "node:test";
import { createHash } from "node:crypto";
import { E04_STORYGRAPH_BOOK_ID } from "./e04-receivers.mjs";

const base = process.env.IPAD_E04_BASE_URL;
const receiver = process.env.IPAD_E04_RECEIVER_URL;
for (const value of [base, receiver]) {
  assert.match(value ?? "", /^http:\/\/(127\.0\.0\.1|localhost):\d+$/, "StoryGraph tests require the isolated E04 server and receiver");
}
const bookID = Number(process.env.IPAD_E04_STORYGRAPH_BOOK_ID ?? 1);
const fileID = Number(process.env.IPAD_E04_STORYGRAPH_FILE_ID ?? 1);
const namespace = createHash("sha256").update("remember_user_token=e04-remember; _storygraph_session=e04-owner").digest("hex").slice(0, 12);
const selectedCase = process.env.IPAD_E04_STORYGRAPH_CASE;
assert.ok(
  selectedCase === undefined || ["permission", "scope", "provider"].includes(selectedCase),
  "Select one StoryGraph case: permission, scope, or provider",
);

function caseOptions(name) {
  return { skip: selectedCase !== undefined && selectedCase !== name };
}

async function request(path, token, method = "GET", body) {
  return fetch(`${base}/api/v1/${path}`, {
    method,
    headers: { ...(token ? { Authorization: `Bearer ${token}` } : {}), ...(body ? { "Content-Type": "application/json" } : {}) },
    ...(body ? { body: JSON.stringify(body) } : {}),
    signal: AbortSignal.timeout(60_000),
  });
}

async function json(path, token, method, body) {
  const response = await request(path, token, method, body);
  assert.ok(response.ok, `${path}: ${response.status} ${await response.clone().text()}`);
  return response.json();
}

async function login(username) {
  return json("auth/login", undefined, "POST", {
    username,
    password: "IpadFixture123",
    clientKind: "native",
    deviceLabel: "StoryGraph public HTTP fixture",
  });
}

async function control(mode, count) {
  const response = await fetch(`${receiver}/control`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ provider: "storygraph", mode, ...(count ? { count } : {}) }),
    signal: AbortSignal.timeout(10_000),
  });
  assert.equal(response.status, 204);
}

async function receipts() {
  let result;
  for (let offset = 0; offset <= 500; offset += 100) {
    const response = await fetch(`${receiver}/receipts?provider=storygraph&limit=100&offset=${offset}`, {
      signal: AbortSignal.timeout(10_000),
    });
    assert.equal(response.status, 200);
    const page = await response.json();
    if (!result) result = page;
    else {
      result.requests.push(...page.requests);
      result.storygraph.books.push(...page.storygraph.books);
    }
    if (page.requests.length < 100 && result.storygraph.books.length === page.storygraph.totalBooks) {
      result.storygraph.books = result.storygraph.books.filter((book) => book.namespace === namespace);
      return result;
    }
  }
  assert.fail("StoryGraph receipt evidence exceeds the bounded acceptance window");
}

function lastReceiptID(evidence) {
  return Math.max(0, ...evidence.requests.map((receipt) => receipt.id));
}

async function withSessions(usernames, action) {
  const sessions = [];
  try {
    for (const username of usernames) sessions.push(await login(username));
    return await action(...sessions);
  } finally {
    const cleanup = await Promise.allSettled(
      sessions.map(async (session) => {
        assert.equal((await request("auth/logout", undefined, "POST", { refreshToken: session.refreshToken })).status, 200);
      }),
    );
    const failures = cleanup.filter((result) => result.status === "rejected").map((result) => result.reason);
    if (failures.length) throw new AggregateError(failures, "StoryGraph fixture session cleanup failed");
  }
}

async function waitForFinal(token, runId) {
  const deadline = Date.now() + 45_000;
  while (Date.now() < deadline) {
    const state = await json("storygraph/sync/status", token);
    if (state?.runId === runId && state.status !== "running") return state;
    await new Promise((resolve) => setTimeout(resolve, 250));
  }
  assert.fail("StoryGraph did not publish a terminal job result");
}

test("IPAD-E04-A05-StoryGraph-HTTP-PERMISSION: anonymous 401 and restricted permission 403", caseOptions("permission"), async () => {
  await withSessions(["ipad-restricted"], async (denied) => {
    for (const [path, method] of [
      ["storygraph/settings", "GET"],
      ["storygraph/books/page", "GET"],
      [`storygraph/books/${bookID}/sync-state`, "GET"],
      [`storygraph/books/${bookID}/sync`, "POST"],
    ]) {
      assert.equal((await request(path, undefined, method)).status, 401, `${method} ${path}: anonymous access`);
      assert.equal((await request(path, denied.accessToken, method)).status, 403, `${method} ${path}: missing StoryGraph permission`);
    }
  });
});

test(
  "IPAD-E04-A05-StoryGraph-HTTP-SCOPE: permitted account has an empty page and inaccessible books stay hidden with 404",
  caseOptions("scope"),
  async () => {
    await withSessions(["ipad-owner", "ipad-restricted"], async (owner, denied) => {
      const token = owner.accessToken;
      const permissions = [...denied.user.permissions];
      const before = await receipts();
      try {
        assert.equal((await request(`users/${denied.user.id}/permissions`, token, "PUT", { permissionNames: ["storygraph_sync"] })).status, 204);
        assert.deepEqual((await json("storygraph/books/page", denied.accessToken)).items, []);
        assert.equal((await request(`storygraph/books/${bookID}/sync-state`, denied.accessToken)).status, 404);
        assert.equal((await request(`storygraph/books/${bookID}/sync`, denied.accessToken, "POST")).status, 404);
        assert.deepEqual((await receipts()).requests, before.requests, "Hidden-book access must not contact StoryGraph");
      } finally {
        assert.equal((await request(`users/${denied.user.id}/permissions`, token, "PUT", { permissionNames: permissions })).status, 204);
      }
    });
  },
);

test(
  "IPAD-E04-A05-StoryGraph-HTTP-PROVIDER: owner export privacy, confirmed outcomes, auth and retry recovery, durable missed events and exclusion",
  caseOptions("provider"),
  async () => {
    await withSessions(["ipad-owner"], async (owner) => {
      const token = owner.accessToken;
      const detail = await json(`books/${bookID}`, token);
      let changedNote = false;
      try {
        const ownerState = await request(`storygraph/books/${bookID}/sync-state`, token);
        assert.equal(ownerState.status, 200);
        assert.equal((await ownerState.json()).bookId, bookID);
        await control("accept");
        assert.equal(
          (await request("storygraph/settings", token, "PATCH", { sessionCookie: "e04-owner", rememberToken: "e04-remember", unknown: true })).status,
          400,
        );
        const settings = await json("storygraph/settings", token, "PATCH", {
          sessionCookie: "e04-owner",
          rememberToken: "e04-remember",
          enabled: true,
          bookSyncMode: "selected_only",
          autoSyncOnStatusChange: false,
          autoSyncOnProgressUpdate: false,
        });
        assert.equal(settings.effectiveEnabled, true);
        assert.equal("sessionCookie" in settings, false);
        assert.equal("rememberToken" in settings, false);
        assert.equal((await json("storygraph/validate-cookies", token, "POST", {})).valid, true);
        await json(`books/${bookID}/status`, token, "PATCH", { status: "reading" });
        await json(`books/${bookID}/personal-note`, token, "PATCH", { note: "StoryGraph private note must stay in BookOrbit" });
        changedNote = true;
        assert.ok((await request(`books/files/${fileID}/progress`, token, "POST", { percentage: 42, source: "text" })).ok);
        await json(`storygraph/books/${bookID}/sync-state`, token, "PATCH", { syncEnabled: true });
        const mapped = await json(`storygraph/books/${bookID}/link`, token, "PATCH", { input: E04_STORYGRAPH_BOOK_ID });
        assert.equal(mapped.success, true);
        const state = await json(`storygraph/books/${bookID}/sync-state`, token);
        assert.ok(state.lastSyncedAt);
        assert.equal(state.syncError, null);
        const received = await receipts();
        const external = received.storygraph.books.find((entry) => entry.id === E04_STORYGRAPH_BOOK_ID);
        assert.equal(external.status, "currently-reading");
        assert.equal(external.progress, 42);
        assert.equal(JSON.stringify(received).includes("StoryGraph private note"), false);
        const unchangedSince = lastReceiptID(received);
        assert.equal((await json(`storygraph/books/${bookID}/sync`, token, "POST")).result, "skipped");
        assert.equal((await receipts()).requests.filter((entry) => entry.id > unchangedSince && entry.accepted && entry.method === "POST").length, 0);
        const page = await json("storygraph/books/page", token);
        assert.ok(page.items.length <= 40);
        assert.equal((await request("storygraph/books/page?afterBookId=0", token)).status, 400);
        await control("auth");
        assert.equal((await json("storygraph/validate-cookies", token, "POST", {})).valid, false);
        assert.ok((await request(`books/files/${fileID}/progress`, token, "POST", { percentage: 43, source: "text" })).ok);
        const failed = await json(`storygraph/books/${bookID}/sync`, token, "POST");
        assert.equal(failed.result, "failed");
        assert.match(failed.state.syncError, /session_expired/);
        await control("accept");
        assert.equal((await json(`storygraph/books/${bookID}/sync`, token, "POST")).result, "synced");
        await control("429", 1);
        assert.equal((await json("storygraph/validate-cookies", token, "POST", {})).valid, true);
        assert.ok((await request(`books/files/${fileID}/progress`, token, "POST", { percentage: 44, source: "text" })).ok);
        await control("timeout-after-receipt");
        assert.equal((await json(`storygraph/books/${bookID}/sync`, token, "POST")).result, "failed");
        const afterAmbiguous = await receipts();
        assert.equal(afterAmbiguous.storygraph.books.find((entry) => entry.id === E04_STORYGRAPH_BOOK_ID).progress, 44);
        await control("accept");
        assert.equal((await json(`storygraph/books/${bookID}/sync`, token, "POST")).result, "synced");
        const afterRetry = await receipts();
        assert.equal(
          afterRetry.requests.filter((entry) => entry.id > lastReceiptID(afterAmbiguous) && entry.accepted && entry.operation === "update-progress")
            .length,
          0,
        );
        const editions = await json(`storygraph/books/${bookID}/editions`, token);
        assert.ok(editions.some((edition) => edition.id === E04_STORYGRAPH_BOOK_ID));
        assert.equal((await json(`storygraph/books/${bookID}/edition`, token, "PATCH", { editionId: E04_STORYGRAPH_BOOK_ID })).success, true);
        const run = await json("storygraph/sync", token, "POST");
        const final = await waitForFinal(token, run.runId);
        assert.equal(final.status, "completed");
        assert.equal(final.failedBooks, 0);
        assert.equal(final.processedBooks, final.totalBooks);
        await withSessions(["ipad-owner"], async (reconnected) => {
          assert.deepEqual(await json("storygraph/sync/status", reconnected.accessToken), final);
        });
        assert.ok((await request(`books/files/${fileID}/progress`, token, "POST", { percentage: 45, source: "text" })).ok);
        await control("malformed");
        assert.equal((await json(`storygraph/books/${bookID}/sync`, token, "POST")).result, "failed");
        await control("accept");
        assert.equal((await json(`storygraph/books/${bookID}/sync`, token, "POST")).result, "synced");
        await json(`storygraph/books/${bookID}/sync-state`, token, "PATCH", { syncEnabled: false });
        assert.ok((await request(`books/files/${fileID}/progress`, token, "POST", { percentage: 46, source: "text" })).ok);
        assert.equal((await json(`storygraph/books/${bookID}/sync`, token, "POST")).result, "skipped");
        assert.equal((await receipts()).storygraph.books.find((entry) => entry.id === E04_STORYGRAPH_BOOK_ID).progress, 45);
      } finally {
        const cleanup = await Promise.allSettled([
          control("accept"),
          (async () => {
            const response = await request("storygraph/settings", token, "DELETE");
            assert.ok(response.status === 200 || response.status === 404, "Idempotent settings cleanup must succeed or already be disconnected");
          })(),
          ...(changedNote ? [json(`books/${bookID}/personal-note`, token, "PATCH", { note: detail.personalNote })] : []),
        ]);
        const failures = cleanup.filter((result) => result.status === "rejected").map((result) => result.reason);
        if (failures.length) throw new AggregateError(failures, "StoryGraph provider fixture cleanup failed");
      }
    });
  },
);
