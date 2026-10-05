import { test } from "node:test";
import assert from "node:assert/strict";
import { createHash, randomBytes } from "node:crypto";
import { createRequire } from "node:module";

const require = createRequire(new URL("../../server/package.json", import.meta.url));
const { PDFDocument } = require("pdf-lib");

const base = "http://localhost:16482/api/v1";
async function request(path, { token, body, method = body ? "POST" : "GET" } = {}) {
  return fetch(`${base}/${path}`, {
    method,
    headers: { ...(token ? { Authorization: `Bearer ${token}` } : {}), ...(body ? { "Content-Type": "application/json" } : {}) },
    body: body ? JSON.stringify(body) : undefined,
  });
}
async function login(username) {
  const response = await request("auth/login", {
    body: { username, password: "IpadFixture123", clientKind: "native", deviceLabel: "iPad HTTP fixture" },
  });
  assert.equal(response.status, 200);
  assert.equal(response.headers.get("set-cookie"), null);
  return response.json();
}

test("IPAD-E01-A01: native credentials rotate and query a bounded 50,000-book library", async () => {
  const session = await login("ipad-owner");
  assert.equal(session.user.isSuperuser, true);
  assert.equal(typeof session.sessionId, "number");
  const query = { sort: [{ field: "title", dir: "asc" }], pagination: { page: 0, size: 40 } };
  const response = await request("books/query", { token: session.accessToken, body: query });
  assert.equal(response.status, 201);
  const page = await response.json();
  assert.equal(page.total, 50_000);
  assert.equal(page.items.length, 40);
  assert.equal(page.size, 40);
  assert.equal(page.page, 0);
  assert.ok(JSON.stringify(page).length < 100_000);
  const search = await request("books/query", { token: session.accessToken, body: { ...query, q: "Orbit fixture" } });
  assert.equal(search.status, 201);
  assert.deepEqual(
    (await search.json()).items.map((book) => book.title),
    ["Orbit fixture"],
  );
  const detail = await (await request("books/1", { token: session.accessToken })).json();
  assert.equal(detail.files.length, 1);
  assert.equal(detail.files[0].format, "pdf");
  const delivery = await request(`books/files/${detail.files[0].id}/serve`, { token: session.accessToken });
  assert.equal(delivery.status, 200);
  assert.match(delivery.headers.get("content-type"), /^application\/pdf/);
  const bytes = new Uint8Array(await delivery.arrayBuffer());
  assert.equal(bytes.length, detail.files[0].sizeBytes);
  assert.equal((await PDFDocument.load(bytes)).getPageCount(), 3);
  const range = await fetch(`${base}/books/files/${detail.files[0].id}/serve`, {
    headers: { Authorization: `Bearer ${session.accessToken}`, Range: "bytes=0-31" },
  });
  assert.equal(range.status, 206);
  assert.equal(range.headers.get("content-range"), `bytes 0-31/${bytes.length}`);
  assert.deepEqual(new Uint8Array(await range.arrayBuffer()), bytes.slice(0, 32));
  const rotated = await request("auth/refresh", { body: { refreshToken: session.refreshToken } });
  assert.equal(rotated.status, 200);
  const next = await rotated.json();
  assert.equal(next.sessionId, session.sessionId);
  assert.notEqual(next.refreshToken, session.refreshToken);
  assert.equal((await request("auth/me", { token: next.accessToken })).status, 200);
  assert.equal((await request("auth/logout", { body: { refreshToken: next.refreshToken } })).status, 200);
  assert.equal((await request("auth/me", { token: next.accessToken })).status, 401);
});

test("IPAD-E01-A05: restricted readers cannot browse or download another library", async () => {
  const session = await login("ipad-restricted");
  assert.deepEqual(await (await request("libraries", { token: session.accessToken })).json(), []);
  const response = await request("books/query", { token: session.accessToken, body: { sort: [], pagination: { page: 0, size: 40 } } });
  assert.equal(response.status, 201);
  assert.equal((await response.json()).total, 0);
  assert.equal((await request("books/1", { token: session.accessToken })).status, 404);
  assert.equal((await request("books/files/1/serve", { token: session.accessToken })).status, 403);
});

test("IPAD-E01-A01: the private and existing native OIDC callbacks coexist", async () => {
  for (const redirectUri of ["bookorbit-private://oauth2-callback", "bookorbit://oauth2-callback"]) {
    const start = await request("auth/oidc/ipad-fixture/state", { body: {} });
    assert.equal(start.status, 200);
    const { state, authorizationEndpoint } = await start.json();
    const codeVerifier = randomBytes(32).toString("base64url");
    const nonce = randomBytes(32).toString("base64url");
    const url = new URL(authorizationEndpoint);
    url.search = new URLSearchParams({
      redirect_uri: redirectUri,
      state,
      nonce,
      client_id: "ipad-test-client",
      code_challenge: createHash("sha256").update(codeVerifier).digest("base64url"),
      code_challenge_method: "S256",
      response_type: "code",
      scope: "openid profile",
    }).toString();
    const authorization = await fetch(url, { redirect: "manual" });
    assert.equal(authorization.status, 302);
    const code = new URL(authorization.headers.get("location")).searchParams.get("code");
    const response = await request("auth/oidc/callback", { body: { code, codeVerifier, redirectUri, nonce, state, clientKind: "native" } });
    assert.equal(response.status, 200);
    const session = await response.json();
    assert.equal(session.user.username, "ipad-owner");
    assert.equal(typeof session.refreshToken, "string");
    assert.equal(response.headers.get("set-cookie"), null);
    assert.equal((await request("auth/me", { token: session.accessToken })).status, 200);
  }
});

test("IPAD-E01-A01: native OIDC callbacks require an exact allowlisted URI", async () => {
  for (const redirectUri of ["bookorbit-private://oauth2-callback?next=evil", "evil://oauth2-callback"]) {
    const start = await request("auth/oidc/ipad-fixture/state", { body: {} });
    const { state } = await start.json();
    const response = await request("auth/oidc/callback", {
      body: {
        code: "fixture-code",
        codeVerifier: "fixture-verifier",
        redirectUri,
        nonce: "fixture-nonce",
        state,
        clientKind: "native",
      },
    });
    assert.equal(response.status, 400);
  }
});
