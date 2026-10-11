import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { mkdtemp, rm } from "node:fs/promises";
import path from "node:path";
import { test } from "node:test";

const base = process.env.IPAD_BASE_URL ?? "http://localhost:16482/api/v1";
async function request(path, token, method = "GET", body) {
  return fetch(`${base}/${path}`, {
    method,
    headers: { ...(token ? { authorization: `Bearer ${token}` } : {}), ...(body ? { "content-type": "application/json" } : {}) },
    body: body ? JSON.stringify(body) : undefined,
    signal: AbortSignal.timeout(30_000),
  });
}
async function json(path, token, method = "GET", body, expected = 200) {
  const response = await request(path, token, method, body);
  assert.equal(response.status, expected, `${method} ${path}: ${await response.clone().text()}`);
  return response.json();
}
async function login(username = "ipad-owner") {
  return json("auth/login", null, "POST", {
    username,
    password: process.env.IPAD_TEST_PASSWORD ?? "IpadFixture123",
    clientKind: "native",
    deviceLabel: "Account administration HTTP proof",
  });
}

test("IPAD-E05-A02-native-magic-link: credentials, session transport, ownership and revocation remain isolated", async () => {
  const owner = await login();
  const shared = await json("users/shared", owner.accessToken, "POST", { username: `e05-shared-${randomUUID()}`, name: "E05 shared reader" }, 201);
  let link;
  try {
    link = await json("auth/magic-links", owner.accessToken, "POST", { userId: shared.id, label: "Native account proof" }, 201);
    const response = await request("auth/magic-links/login", null, "POST", { token: link.token, clientKind: "native", deviceLabel: "Private iPad" });
    assert.equal(response.status, 200, await response.clone().text());
    assert.equal(response.headers.has("set-cookie"), false);
    const native = await response.json();
    assert.equal(native.user.id, shared.id);
    assert.equal(native.user.authenticationMethod, "magic_link");
    assert.equal(typeof native.refreshToken, "string");
    assert.equal(typeof native.refreshTokenExpiresAt, "string");
    const sessions = await json("auth/sessions", native.accessToken);
    assert.deepEqual(
      sessions.map(({ clientKind, deviceLabel }) => ({ clientKind, deviceLabel })),
      [{ clientKind: "native", deviceLabel: "Private iPad" }],
    );
    assert.equal((await request(`auth/sessions/${owner.sessionId}`, native.accessToken, "DELETE")).status, 403);
    const refreshed = await json("auth/refresh", null, "POST", { refreshToken: native.refreshToken });
    assert.equal(refreshed.sessionId, native.sessionId);
    assert.equal((await request(`auth/magic-links/${link.id}`, owner.accessToken, "DELETE")).status, 204);
    assert.equal((await request("auth/me", refreshed.accessToken)).status, 401);
    assert.equal((await request("auth/refresh", null, "POST", { refreshToken: refreshed.refreshToken })).status, 401);
    assert.equal((await request("auth/me", owner.accessToken)).status, 200);
    assert.equal((await request("auth/magic-links/login", null, "POST", { token: link.token, clientKind: "native" })).status, 401);
  } finally {
    if (link) await request(`auth/magic-links/${link.id}`, owner.accessToken, "DELETE");
    await request(`users/${shared.id}`, owner.accessToken, "DELETE");
  }
});

test("IPAD-E05-A04-library-scope: metadata administrators cannot inspect or alter unassigned libraries", async () => {
  const owner = await login();
  const libraries = await json("libraries", owner.accessToken);
  assert.ok(libraries.length > 0, "A seeded library is required");
  const libraryId = libraries[0].id;
  const shared = await json(
    "users/shared",
    owner.accessToken,
    "POST",
    {
      username: `e05-admin-${randomUUID()}`,
      name: "E05 restricted administrator",
      permissionNames: ["manage_libraries", "manage_metadata_config", "manage_users"],
    },
    201,
  );
  let link;
  try {
    link = await json("auth/magic-links", owner.accessToken, "POST", { userId: shared.id, label: "Restricted administration proof" }, 201);
    const admin = await json("auth/magic-links/login", null, "POST", { token: link.token });
    assert.equal((await request(`metadata-preferences/libraries/${libraryId}`, admin.accessToken)).status, 403);
    assert.equal((await request(`metadata-preferences/libraries/${libraryId}`, admin.accessToken, "PUT", { overrides: {} })).status, 403);
    assert.equal((await request(`metadata-preferences/libraries/${libraryId}`, admin.accessToken, "DELETE")).status, 403);
    assert.equal((await request(`libraries/${libraryId}/access`, admin.accessToken)).status, 403);
    assert.equal(
      (await request(`libraries/${libraryId}/access`, admin.accessToken, "POST", { userId: shared.id, accessLevel: "owner" })).status,
      403,
    );
    assert.equal((await request(`libraries/${libraryId}/access/${owner.user.id}`, admin.accessToken, "DELETE")).status, 403);
    assert.equal((await request(`users/${owner.user.id}/superuser`, admin.accessToken, "PUT", { isSuperuser: false })).status, 403);
    assert.equal(
      (await request("users/shared", admin.accessToken, "POST", { username: `e05-denied-${randomUUID()}`, name: "Denied shared reader" })).status,
      403,
    );
    assert.equal((await request("auth/oidc/unknown-provider/preview-state", admin.accessToken, "POST")).status, 403);
    assert.equal((await request("users?page=0&pageSize=20", admin.accessToken)).status, 200);
    assert.equal((await request("auth/me", owner.accessToken)).status, 200);
  } finally {
    if (link) await request(`auth/magic-links/${link.id}`, owner.accessToken, "DELETE");
    await request(`users/${shared.id}`, owner.accessToken, "DELETE");
  }
});

test("IPAD-E05-A03-library-creator: authorized non-superuser owns the library they create", async () => {
  const owner = await login();
  const libraries = await json("libraries", owner.accessToken);
  const root = libraries.find((library) => library.folders?.length)?.folders[0].path;
  assert.ok(root && root.includes("bookorbit-ipad-"), "An isolated content root is required");
  const folder = await mkdtemp(path.join(root, "e05-library-"));
  const shared = await json(
    "users/shared",
    owner.accessToken,
    "POST",
    {
      username: `e05-creator-${randomUUID()}`,
      name: "E05 library administrator",
      permissionNames: ["manage_libraries"],
    },
    201,
  );
  let link;
  let created;
  try {
    link = await json("auth/magic-links", owner.accessToken, "POST", { userId: shared.id, label: "Library creator proof" }, 201);
    const admin = await json("auth/magic-links/login", null, "POST", { token: link.token });
    created = await json(
      "libraries",
      admin.accessToken,
      "POST",
      { name: `E05 creator ${randomUUID()}`, icon: "BookOpen", folders: [folder], watch: false },
      201,
    );
    assert.ok((await json("libraries", admin.accessToken)).some((library) => library.id === created.id));
    assert.equal((await json(`libraries/${created.id}`, admin.accessToken)).id, created.id);
    assert.equal((await request(`libraries/${created.id}/access`, admin.accessToken)).status, 200);
    assert.equal((await request(`libraries/${created.id}`, admin.accessToken, "PATCH", { name: `E05 edited ${randomUUID()}` })).status, 200);
    assert.equal((await request(`libraries/${created.id}`, admin.accessToken, "DELETE")).status, 204);
    created = undefined;
  } finally {
    if (created) await request(`libraries/${created.id}`, owner.accessToken, "DELETE");
    if (link) await request(`auth/magic-links/${link.id}`, owner.accessToken, "DELETE");
    await request(`users/${shared.id}`, owner.accessToken, "DELETE");
    await rm(folder, { recursive: true, force: true });
  }
});
