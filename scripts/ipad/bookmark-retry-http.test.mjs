import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { test } from "node:test";

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
    body: { username, password: "IpadFixture123", clientKind: "native", deviceLabel: "Bookmark retry HTTP fixture" },
  });
  assert.equal(response.status, 200);
  return response.json();
}

async function record(path, token) {
  const response = await request(path, { token });
  assert.equal(response.status, 200, await response.clone().text());
  return response.json();
}

test("IPAD-E02-A04/A05-bookmark-epub-retry: lost create replies and committed deletion keep their operation identity", async () => {
  const owner = await login("ipad-owner");
  const reader = await login("ipad-reader");
  const clientId = randomUUID();
  const body = { clientId, cfi: `epubcfi(/6/2!/4/2/1[${clientId}]:0)`, title: `Retry bookmark ${clientId}` };
  let readerPermissionChanged = false;
  try {
    const initial = await request("books/2/bookmarks", { token: owner.accessToken, body });
    assert.equal(initial.status, 201, await initial.clone().text());
    const created = await initial.json();
    assert.equal(created.clientId, clientId);
    const retry = await request("books/2/bookmarks", { token: owner.accessToken, body });
    assert.equal(retry.status, 201);
    assert.equal((await retry.json()).id, created.id);
    assert.equal((await record("books/2/bookmarks", owner.accessToken)).filter((item) => item.clientId === clientId).length, 1);
    const grant = await request(`users/${reader.user.id}/permissions`, {
      token: owner.accessToken,
      method: "PUT",
      body: { permissionNames: [...new Set([...reader.user.permissions, "library_download"])] },
    });
    assert.equal(grant.status, 204);
    readerPermissionChanged = true;
    const foreignDelete = await request(`books/2/bookmarks/${created.id}`, { token: reader.accessToken, method: "DELETE" });
    assert.ok([403, 404].includes(foreignDelete.status));
    const denyOwnAnnotations = await request(`users/${reader.user.id}/permissions`, {
      token: owner.accessToken,
      method: "PUT",
      body: {
        permissionNames: [
          ...new Set([...reader.user.permissions.filter((permission) => permission !== "annotation_manage_own"), "library_download"]),
        ],
      },
    });
    assert.equal(denyOwnAnnotations.status, 204);
    assert.equal((await request("books/2/bookmarks", { token: reader.accessToken, body: { ...body, clientId: randomUUID() } })).status, 403);
    assert.equal((await request(`books/2/bookmarks/${created.id}`, { token: reader.accessToken, method: "DELETE" })).status, 403);
    assert.equal((await request("books/2/bookmarks", { token: owner.accessToken, body: { ...body, cfi: "epubcfi(/6/2!/4/6:0)" } })).status, 409);
    const deletion = await request(`books/2/bookmarks/${created.id}`, { token: owner.accessToken, method: "DELETE" });
    assert.equal(deletion.status, 204);
    assert.equal((await request("books/2/bookmarks", { token: owner.accessToken, body })).status, 409);
    assert.ok(!(await record("books/2/bookmarks", owner.accessToken)).some((item) => item.clientId === clientId));
    const newClientId = randomUUID();
    const explicit = await request("books/2/bookmarks", { token: owner.accessToken, body: { ...body, clientId: newClientId } });
    assert.equal(explicit.status, 201, await explicit.clone().text());
    const replacement = await explicit.json();
    assert.notEqual(replacement.id, created.id);
    assert.equal(replacement.clientId, newClientId);
    assert.equal((await request("books/2/bookmarks", { token: owner.accessToken, body })).status, 409);
    assert.equal((await request(`books/2/bookmarks/${created.id}`, { token: owner.accessToken, method: "DELETE" })).status, 204);
    assert.ok((await record("books/2/bookmarks", owner.accessToken)).some((item) => item.id === replacement.id));
  } finally {
    if (readerPermissionChanged)
      assert.equal(
        (
          await request(`users/${reader.user.id}/permissions`, {
            token: owner.accessToken,
            method: "PUT",
            body: { permissionNames: reader.user.permissions },
          })
        ).status,
        204,
      );
    for (const session of [owner, reader]) assert.equal((await request("auth/logout", { body: { refreshToken: session.refreshToken } })).status, 200);
  }
});

for (const [format, bookId, pageNumber] of [
  ["pdf", 1, 3],
  ["cbz", 10, 3],
]) {
  test(`IPAD-E02-A04/A05-bookmark-${format}-retry: fixed-page retries retain deletion and allow a fresh identity`, async () => {
    const owner = await login("ipad-owner");
    try {
      const fileId = (await record(`books/${bookId}`, owner.accessToken)).files.find((file) => file.format === format).id;
      const pageRoute = `books/${bookId}/bookmarks/page?fileId=${fileId}&limit=100`;
      const existing = (await record(pageRoute, owner.accessToken)).items.find((item) => item.pageNumber === pageNumber);
      if (existing) {
        assert.match(existing.title, /^Fixed retry /);
        assert.equal((await request(`books/${bookId}/bookmarks/${existing.id}`, { token: owner.accessToken, method: "DELETE" })).status, 204);
      }
      const clientId = randomUUID();
      const body = { clientId, fileId, pageNumber, title: `Fixed retry ${clientId}` };
      const route = `books/${bookId}/bookmarks/fixed-page`;
      const initial = await request(route, { token: owner.accessToken, body });
      assert.equal(initial.status, 201, await initial.clone().text());
      await initial.arrayBuffer();
      const retry = await request(route, { token: owner.accessToken, body });
      assert.equal(retry.status, 201);
      const created = await retry.json();
      assert.equal(created.clientId, clientId);
      assert.equal((await record(pageRoute, owner.accessToken)).items.filter((item) => item.clientId === clientId).length, 1);
      assert.equal((await request(`books/${bookId}/bookmarks/${created.id}`, { token: owner.accessToken, method: "DELETE" })).status, 204);
      assert.equal((await request(route, { token: owner.accessToken, body })).status, 409);
      assert.ok(!(await record(pageRoute, owner.accessToken)).items.some((item) => item.clientId === clientId));
      const newClientId = randomUUID();
      const replacementResponse = await request(route, { token: owner.accessToken, body: { ...body, clientId: newClientId } });
      assert.equal(replacementResponse.status, 201);
      const replacement = await replacementResponse.json();
      assert.notEqual(replacement.id, created.id);
      assert.equal(replacement.clientId, newClientId);
      assert.equal((await request(route, { token: owner.accessToken, body })).status, 409);
      assert.equal((await request(`books/${bookId}/bookmarks/${created.id}`, { token: owner.accessToken, method: "DELETE" })).status, 204);
      assert.ok((await record(pageRoute, owner.accessToken)).items.some((item) => item.clientId === newClientId));
    } finally {
      assert.equal((await request("auth/logout", { body: { refreshToken: owner.refreshToken } })).status, 200);
    }
  });
}

test("IPAD-E02-A04/A05-bookmark-audio-retry: uncertain audio operations cannot restore a deleted identity", async () => {
  const owner = await login("ipad-owner");
  const clientId = randomUUID();
  const route = "audiobooks/6/bookmarks";
  const body = { clientId, positionMs: 123, title: `Audio retry ${clientId}` };
  try {
    const prior = (await record(`${route}/page?limit=100`, owner.accessToken)).items.find((item) => item.positionMs === body.positionMs);
    if (prior) {
      assert.match(prior.title, /^Audio retry /);
      assert.equal((await request(`${route}/${prior.id}`, { token: owner.accessToken, method: "DELETE" })).status, 204);
    }
    const initial = await request(route, { token: owner.accessToken, body });
    assert.equal(initial.status, 201, await initial.clone().text());
    await initial.arrayBuffer();
    const retry = await request(route, { token: owner.accessToken, body });
    assert.equal(retry.status, 201);
    assert.equal((await retry.json()).id, clientId);
    assert.equal((await record(`${route}/page?limit=100`, owner.accessToken)).items.filter((item) => item.id === clientId).length, 1);
    assert.equal((await request(`${route}/${clientId}`, { token: owner.accessToken, method: "DELETE" })).status, 204);
    assert.equal((await request(route, { token: owner.accessToken, body })).status, 409);
    const replacement = await request(route, { token: owner.accessToken, body: { ...body, clientId: randomUUID() } });
    assert.equal(replacement.status, 201);
    const newId = (await replacement.json()).id;
    assert.notEqual(newId, clientId);
    assert.equal((await request(route, { token: owner.accessToken, body })).status, 409);
    assert.equal((await request(`${route}/${clientId}`, { token: owner.accessToken, method: "DELETE" })).status, 204);
    assert.ok((await record(`${route}/page?limit=100`, owner.accessToken)).items.some((item) => item.id === newId));
  } finally {
    assert.equal((await request("auth/logout", { body: { refreshToken: owner.refreshToken } })).status, 200);
  }
});
