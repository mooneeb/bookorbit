import { test } from "node:test";
import assert from "node:assert/strict";
import { createHash, randomUUID } from "node:crypto";

const base = process.env.IPAD_E04_HTTP_BASE ?? "http://127.0.0.1:16502/api/v1";
const receiver = process.env.IPAD_E04_RECEIVER_URL;

async function request(path, token, method = "GET", body) {
  return fetch(`${base}/${path}`, {
    method,
    headers: { ...(token ? { Authorization: `Bearer ${token}` } : {}), ...(body ? { "Content-Type": "application/json" } : {}) },
    body: body ? JSON.stringify(body) : undefined,
  });
}
async function json(path, token, method = "GET", body, expected = method === "POST" ? 201 : 200) {
  const response = await request(path, token, method, body);
  assert.equal(response.status, expected, `${method} ${path}: ${await response.clone().text()}`);
  const payload = await response.text();
  return payload.length === 0 ? null : JSON.parse(payload);
}
async function login(username) {
  return json(
    "auth/login",
    null,
    "POST",
    { username, password: "IpadFixture123", clientKind: "native", deviceLabel: "Readwise HTTP acceptance" },
    200,
  );
}
async function control(mode, count) {
  assert.ok(receiver, "IPAD_E04_RECEIVER_URL must identify the controlled provider");
  const response = await fetch(`${receiver}/control`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ provider: "readwise", mode, ...(count ? { count } : {}) }),
  });
  assert.equal(response.status, 204);
}
async function receipts() {
  const response = await fetch(`${receiver}/receipts?limit=100`);
  assert.equal(response.status, 200);
  return response.json();
}
async function waitStatus(token, predicate, timeout = 20_000) {
  const start = Date.now();
  let status;
  while (Date.now() - start < timeout) {
    status = await json("readwise/sync/status", token);
    if (predicate(status)) return status;
    await new Promise((resolve) => setTimeout(resolve, 150));
  }
  assert.fail(`Readwise status did not converge: ${JSON.stringify(status)}`);
}

test("IPAD-E04-QA5-Readwise-http: real authenticated export, receipts, retry, auth recovery, isolation and bounded batches", async (t) => {
  const owner = await login("ipad-owner");
  const other = await login("ipad-reader");
  const restricted = await login("ipad-restricted");
  const marker = `readwise-e04-${randomUUID()}`;
  const created = [];
  const token = owner.accessToken;
  const initialCredential = "fixture-readwise";
  const reconnectedCredential = "fixture-readwise-reconnected";
  function accountHighlights(records, credential) {
    const namespace = createHash("sha256").update(`Token ${credential}`).digest("hex").slice(0, 12);
    return records.filter((highlight) => highlight.namespace === namespace);
  }
  async function allReceivedHighlights() {
    const evidence = await receipts();
    const all = [];
    for (let offset = 0; offset < evidence.readwise.totalHighlights; offset += 100) {
      const response = await fetch(`${receiver}/receipts?limit=100&offset=${offset}`);
      assert.equal(response.status, 200);
      all.push(...(await response.json()).readwise.highlights);
    }
    return all;
  }
  async function highlight(text, bookId = 1, session = owner) {
    const annotation = await json(`books/${bookId}/annotations`, session.accessToken, "POST", {
      cfi: "epubcfi(/6/2!/4/2:0)",
      text,
      color: "yellow",
      style: "highlight",
      note: `${marker}-note`,
    });
    created.push({ bookId, id: annotation.id, token: session.accessToken });
    return annotation;
  }
  try {
    await control("accept");
    await t.test("IPAD-E04-QA5-RW01-contract-permission-and-mapping", async () => {
      assert.equal((await request("readwise/settings")).status, 401);
      assert.equal((await request("readwise/settings", restricted.accessToken)).status, 403);
      assert.equal((await request("readwise/sync", restricted.accessToken, "POST")).status, 403);
      assert.equal((await request("readwise/settings", token, "PATCH", { apiToken: initialCredential, unexpected: true })).status, 400);
      assert.deepEqual(await json("readwise/validate-token", token, "POST", { token: "invalid-fixture" }), { valid: false });
      assert.deepEqual(await json("readwise/validate-token", token, "POST", { token: initialCredential }), { valid: true });
      const connected = await json("readwise/settings", token, "PATCH", { apiToken: initialCredential, enabled: false });
      assert.equal(connected.tokenConfigured, true);
      assert.equal(Object.hasOwn(connected, "apiToken"), false);
      await highlight(`${marker}-other-user`, 1, other);
      await json("readwise/settings", token, "PATCH", { enabled: true });
      const annotation = await highlight(`${marker}-mapped`);
      await json("readwise/sync", token, "POST");
      const status = await waitStatus(token, (s) => s.state === "succeeded" && s.pendingHighlights === 0);
      assert.ok(status.exportedHighlights >= 1);
      assert.ok(status.receivedBookIds.length >= 1);
      const received = accountHighlights(await allReceivedHighlights(), initialCredential).filter((h) => h.text.startsWith(marker));
      assert.equal(received.length, 1);
      assert.equal(received[0].text, `${marker}-mapped`);
      assert.equal(received[0].note, `${marker}-note`);
      assert.equal(received[0].source_type, "bookorbit");
      assert.equal(received[0].category, "books");
      assert.ok(received[0].highlight_url.endsWith(`annotationId=${annotation.id}`));
      assert.equal(Object.hasOwn(received[0], "drawing"), false);
      assert.equal(
        received.some((h) => h.text.endsWith("other-user")),
        false,
      );
      await json("readwise/sync", token, "POST");
      await waitStatus(token, (s) => s.state === "succeeded");
      assert.equal(accountHighlights(await allReceivedHighlights(), initialCredential).filter((h) => h.text === `${marker}-mapped`).length, 1);
    });
    await t.test("IPAD-E04-QA5-RW05-revoked-library-access-excludes-retained-private-highlights", async () => {
      const editor = await login("ipad-editor");
      const userId = editor.user.id;
      const originalPermissions = editor.user.permissions;
      const book = await json("books/1", token);
      const libraryId = book.libraryId;
      const access = await json(`libraries/${libraryId}/access`, token);
      const originalAccess = access.find((row) => row.userId === userId);
      assert.ok(originalAccess, "editor needs the fixture library membership");
      try {
        assert.equal(
          (await request(`users/${userId}/permissions`, token, "PUT", { permissionNames: [...new Set([...originalPermissions, "readwise_sync"])] }))
            .status,
          204,
        );
        await json("readwise/settings", editor.accessToken, "PATCH", { apiToken: "fixture-readwise-scope", enabled: false });
        await highlight(`${marker}-revoked-library`, 1, editor);
        assert.equal((await request(`libraries/${libraryId}/access/${userId}`, token, "DELETE")).status, 204);
        await json("readwise/settings", editor.accessToken, "PATCH", { enabled: true, includeExistingHighlights: true });
        await json("readwise/sync", editor.accessToken, "POST");
        const status = await waitStatus(editor.accessToken, (value) => value.state === "succeeded");
        assert.equal(status.pendingHighlights, 0);
        assert.equal(
          accountHighlights(await allReceivedHighlights(), "fixture-readwise-scope").some((row) => row.text === `${marker}-revoked-library`),
          false,
        );
      } finally {
        const restored = await json(`libraries/${libraryId}/access`, token, "POST", { userId, accessLevel: originalAccess.accessLevel }, 201);
        assert.equal(restored, null);
        const restoredAccess = await json(`libraries/${libraryId}/access`, token);
        assert.equal(restoredAccess.find((row) => row.userId === userId)?.accessLevel, originalAccess.accessLevel);
        await request("readwise/settings", editor.accessToken, "PATCH", { enabled: false });
        assert.equal((await request(`users/${userId}/permissions`, token, "PUT", { permissionNames: originalPermissions })).status, 204);
        for (let index = created.length - 1; index >= 0; index--) {
          const annotation = created[index];
          if (annotation.token !== editor.accessToken) continue;
          assert.equal((await request(`books/${annotation.bookId}/annotations/${annotation.id}`, annotation.token, "DELETE")).status, 204);
          created.splice(index, 1);
        }
        await request("auth/logout", null, "POST", { refreshToken: editor.refreshToken });
      }
    });
    await t.test("IPAD-E04-QA5-RW02-incomplete-receipts-timeouts-and-idempotent-retry", async () => {
      for (const mode of ["malformed", "500", "timeout-after-receipt"]) {
        await control(mode);
        await highlight(`${marker}-${mode}`);
        await json("readwise/sync", token, "POST");
        const failed = await waitStatus(token, (s) => s.state === "failed");
        assert.ok(failed.pendingHighlights >= 1);
        assert.ok(failed.error.includes("could not be confirmed"));
        await control("accept");
        await json("readwise/sync", token, "POST");
        await waitStatus(token, (s) => s.state === "succeeded" && s.pendingHighlights === 0);
        assert.equal(accountHighlights(await allReceivedHighlights(), initialCredential).filter((h) => h.text === `${marker}-${mode}`).length, 1);
      }
      await control("429", 1);
      await highlight(`${marker}-rate-limit`);
      await json("readwise/sync", token, "POST");
      await waitStatus(token, (s) => s.state === "succeeded" && s.pendingHighlights === 0);
      assert.equal(accountHighlights(await allReceivedHighlights(), initialCredential).filter((h) => h.text === `${marker}-rate-limit`).length, 1);
    });
    await t.test("IPAD-E04-QA5-RW03-auth-rejection-and-reconnect-resume", async () => {
      await control("auth");
      await highlight(`${marker}-auth-reconnect`);
      await json("readwise/sync", token, "POST");
      await waitStatus(token, (s) => s.state === "failed");
      const disabled = await json("readwise/settings", token);
      assert.equal(disabled.disabledReason, "invalid_token");
      assert.equal(disabled.effectiveEnabled, false);
      assert.equal((await request("readwise/sync", token, "POST")).status, 400);
      await control("accept");
      await json("readwise/settings", token, "PATCH", { apiToken: reconnectedCredential, enabled: true });
      await json("readwise/sync", token, "POST");
      await waitStatus(token, (s) => s.state === "succeeded" && s.pendingHighlights === 0);
      assert.equal(
        accountHighlights(await allReceivedHighlights(), reconnectedCredential).filter((h) => h.text === `${marker}-auth-reconnect`).length,
        1,
      );
    });
    await t.test("IPAD-E04-QA5-RW04-bounded-server-batching-without-native-fanout", async () => {
      await json("readwise/settings", token, "PATCH", { enabled: false });
      for (let offset = 0; offset < 105; offset += 10) {
        await Promise.all(Array.from({ length: Math.min(10, 105 - offset) }, (_, index) => highlight(`${marker}-batch-${offset + index}`)));
      }
      await json("readwise/settings", token, "PATCH", { enabled: true, includeExistingHighlights: true });
      await json("readwise/sync", token, "POST");
      await waitStatus(token, (s) => s.state === "succeeded" && s.pendingHighlights === 0, 30_000);
      const evidence = await receipts();
      const requests = evidence.requests.filter((r) => r.provider === "readwise" && r.operation === "createHighlights" && r.accepted);
      assert.ok(requests.length >= 2);
      assert.ok(requests.every((r) => r.payload.count <= 100));
      const all = await allReceivedHighlights();
      const currentAccount = accountHighlights(all, reconnectedCredential);
      const originalAccount = accountHighlights(all, initialCredential);
      assert.equal(currentAccount.filter((h) => h.text.startsWith(`${marker}-batch-`)).length, 105);
      assert.equal(currentAccount.filter((h) => h.text === `${marker}-mapped`).length, 1);
      assert.equal(originalAccount.filter((h) => h.text === `${marker}-mapped`).length, 1);
      const receivedIds = currentAccount
        .filter((h) => h.text.startsWith(marker))
        .map((h) => h.id)
        .sort((a, b) => a - b);
      await json("readwise/settings", token, "PATCH", { enabled: true, includeExistingHighlights: true });
      await json("readwise/sync", token, "POST");
      await waitStatus(token, (s) => s.state === "succeeded" && s.pendingHighlights === 0, 30_000);
      const retriedAccount = accountHighlights(await allReceivedHighlights(), reconnectedCredential);
      assert.deepEqual(
        retriedAccount
          .filter((h) => h.text.startsWith(marker))
          .map((h) => h.id)
          .sort((a, b) => a - b),
        receivedIds,
      );
      assert.equal(retriedAccount.filter((h) => h.text.startsWith(`${marker}-batch-`)).length, 105);
    });
  } finally {
    await control("accept");
    await request("readwise/settings", token, "PATCH", { enabled: false });
    for (const annotation of created) await request(`books/${annotation.bookId}/annotations/${annotation.id}`, annotation.token, "DELETE");
    for (const session of [owner, other, restricted]) await request("auth/logout", null, "POST", { refreshToken: session.refreshToken });
  }
});
