import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { test } from "node:test";
import { startRequestAdminFixture, createSignedRequestPluginUpdate } from "./e03-request-admin-fixture.mjs";

const base = process.env.IPAD_E03_BASE_URL ?? "http://localhost:16482/api/v1";
async function call(path, token, body, method = body ? "POST" : "GET") {
  return fetch(`${base}/${path}`, {
    method,
    headers: { ...(token ? { Authorization: `Bearer ${token}` } : {}), ...(body ? { "content-type": "application/json" } : {}) },
    body: body ? JSON.stringify(body) : undefined,
  });
}
async function login(username) {
  const response = await call("auth/login", null, {
    username,
    password: "IpadFixture123",
    clientKind: "native",
    deviceLabel: "Request admin fixture",
  });
  assert.equal(response.status, 200, username);
  return response.json();
}

test("IPAD-E03-REQUEST-ADMIN-01: settings operator validates sources and clients without seeing stored secrets", async () => {
  const operator = await login("ipad-settings-admin");
  const moderator = await login("ipad-request-moderator");
  const fixture = await startRequestAdminFixture({ port: 0 });
  const ids = [];
  try {
    for (const path of ["admin/request-indexers", "admin/download-clients", "admin/book-request-automation"]) {
      assert.equal((await call(path, moderator.accessToken)).status, 403, path);
      assert.equal((await call(path)).status, 401, path);
    }
    const indexerResponse = await call("admin/request-indexers", operator.accessToken, {
      name: `E03 source ${Date.now()}`,
      adapterType: "torznab",
      baseUrl: `${fixture.origin}/torznab`,
      credential: "secret-test-key",
      allowPrivateAddress: true,
      enabled: true,
    });
    assert.equal(indexerResponse.status, 201);
    const indexer = await indexerResponse.json();
    ids.push(["admin/request-indexers", indexer.id]);
    assert.equal(indexer.hasCredential, true);
    assert.equal(indexer.credential, undefined);
    const indexerTest = await call(`admin/request-indexers/${indexer.id}/test`, operator.accessToken, {});
    assert.equal(indexerTest.status, 200);
    assert.equal((await indexerTest.json()).success, true);
    const clientResponse = await call("admin/download-clients", operator.accessToken, {
      name: `E03 client ${Date.now()}`,
      adapterType: "qbittorrent",
      baseUrl: fixture.origin,
      username: "fixture",
      password: "secret-test-password",
      allowPrivateAddress: true,
      pathMappings: [{ remotePath: "/downloads", localPath: process.env.IPAD_E03_DOWNLOAD_PATH ?? "/tmp" }],
    });
    assert.equal(clientResponse.status, 201);
    const client = await clientResponse.json();
    ids.push(["admin/download-clients", client.id]);
    assert.equal(client.hasPassword, true);
    assert.equal(client.password, undefined);
    const clientTest = await call(`admin/download-clients/${client.id}/test`, operator.accessToken, {});
    assert.equal(clientTest.status, 200);
    assert.equal((await clientTest.json()).success, true);
    const forbidden = await call("admin/request-indexers/plugins/updates", operator.accessToken);
    assert.equal(forbidden.status, 403);
    assert.equal((await call(`admin/request-indexers/${indexer.id}`, operator.accessToken, { unexpected: true }, "PUT")).status, 400);
    assert.equal((await call("admin/book-request-automation", operator.accessToken, { autoGrabMinScore: 49 }, "PUT")).status, 400);
  } finally {
    for (const [path, id] of ids.reverse()) assert.equal((await call(`${path}/${id}`, operator.accessToken, undefined, "DELETE")).status, 204);
    await call("auth/logout", null, { refreshToken: operator.refreshToken });
    await call("auth/logout", null, { refreshToken: moderator.refreshToken });
    await fixture.close();
  }
});

test("IPAD-E03-REQUEST-ADMIN-02: language preference is scoped to the authenticated reader and validates languages", async () => {
  const owner = await login("ipad-owner");
  const reader = await login("ipad-reader");
  const ownerBefore = await (await call("user-preferences/book-requests", owner.accessToken)).json();
  try {
    const before = await (await call("user-preferences/book-requests", reader.accessToken)).json();
    assert.equal((await call("user-preferences/book-requests", owner.accessToken, { settings: { defaultLanguage: "de" } }, "PUT")).status, 204);
    assert.equal((await (await call("user-preferences/book-requests", owner.accessToken)).json()).settings.defaultLanguage, "de");
    assert.deepEqual(await (await call("user-preferences/book-requests", reader.accessToken)).json(), before);
    assert.equal((await call("user-preferences/book-requests", owner.accessToken, { settings: { defaultLanguage: "unknown" } }, "PUT")).status, 400);
  } finally {
    await call("user-preferences/book-requests", owner.accessToken, ownerBefore, "PUT");
    await call("auth/logout", null, { refreshToken: owner.refreshToken });
    await call("auth/logout", null, { refreshToken: reader.refreshToken });
  }
});

test("IPAD-E03-REQUEST-ADMIN-05: native automation destinations and ordered tiers persist with bounded validated settings", async () => {
  const operator = await login("ipad-settings-admin");
  const previousResponse = await call("admin/book-request-automation", operator.accessToken);
  assert.equal(previousResponse.status, 200);
  const previous = await previousResponse.json();
  try {
    const libraries = await (await call("libraries", operator.accessToken)).json();
    const library = libraries.find((item) => item.type === "books" && item.folders.length > 0);
    assert.ok(library, "Settings operator has an accessible destination library");
    const payload = {
      autoGrabEnabled: false,
      autoGrabMinScore: 82,
      autoRetryEnabled: true,
      maxAutoGrabAttempts: 4,
      autoSearchEnabled: false,
      autoSearchIntervalHours: 36,
      autoSearchMaxAgeDays: 45,
      verificationEnabled: true,
      verificationThreshold: 76,
      importFormats: "preferred",
      destinations: { ebook: { libraryId: library.id, folderId: library.folders[0].id } },
      profiles: {
        ebook: [
          { id: "epub-first", name: "Preferred EPUB", conditions: { formats: ["epub"], excludeVipOnly: true } },
          { id: "pdf-second", name: "PDF alternative", conditions: { formats: ["pdf"] } },
        ],
      },
    };
    const response = await call("admin/book-request-automation", operator.accessToken, payload, "PUT");
    assert.equal(response.status, 200);
    const result = await response.json();
    assert.equal(result.autoGrabMinScore, 82);
    assert.deepEqual(
      result.profiles.ebook.map((tier) => tier.id),
      ["epub-first", "pdf-second"],
    );
    assert.deepEqual(result.destinations.ebook, payload.destinations.ebook);
    assert.deepEqual(await (await call("admin/book-request-automation", operator.accessToken)).json(), result);
    assert.equal(
      (
        await call(
          "admin/book-request-automation",
          operator.accessToken,
          { profiles: { ebook: Array.from({ length: 13 }, (_, id) => ({ id: String(id), name: "Too many", conditions: {} })) } },
          "PUT",
        )
      ).status,
      400,
    );
  } finally {
    assert.equal((await call("admin/book-request-automation", operator.accessToken, previous, "PUT")).status, 200);
    await call("auth/logout", null, { refreshToken: operator.refreshToken });
  }
});

test("IPAD-E03-REQUEST-ADMIN-06: only a superuser can inspect install and remove a reviewed plugin", async () => {
  const operator = await login("ipad-settings-admin");
  const owner = await login("ipad-owner");
  const type = `e03-proof-${Date.now()}`;
  const source = `export default { apiVersion: 1, type: '${type}', label: 'E03 controlled plugin', version: '1.0.0', requiresCredential: false, mediaKinds: ['ebook'], usesCategories: false, seedsBack: false, search: async () => [], test: async () => ({ success: true }), resolveFile: async () => ({ url: 'https://example.invalid/book.pdf' }) };`;
  async function upload(path, token) {
    const form = new FormData();
    form.append("file", new Blob([source], { type: "text/javascript" }), "controlled.mjs");
    return fetch(`${base}/${path}`, { method: "POST", headers: { Authorization: `Bearer ${token}` }, body: form });
  }
  let installed = false;
  try {
    assert.equal((await upload("admin/request-indexers/plugins/inspect", operator.accessToken)).status, 403);
    const reviewResponse = await upload("admin/request-indexers/plugins/inspect", owner.accessToken);
    assert.equal(reviewResponse.status, 200);
    const review = await reviewResponse.json();
    assert.equal(review.source, source);
    assert.equal(review.replaces, false);
    const installResponse = await upload("admin/request-indexers/plugins", owner.accessToken);
    assert.equal(installResponse.status, 201);
    installed = true;
    assert.equal((await installResponse.json()).active, true);
    const adapters = await (await call("admin/request-indexers/adapters", operator.accessToken)).json();
    const adapter = adapters.adapters.find((item) => item.type === type);
    assert.equal(adapter.builtIn, false);
    assert.equal(adapter.delivery, "file");
    assert.equal((await call(`admin/request-indexers/plugins/${type}`, operator.accessToken, undefined, "DELETE")).status, 403);
    assert.equal((await call(`admin/request-indexers/plugins/${type}`, owner.accessToken, undefined, "DELETE")).status, 204);
    installed = false;
    const removed = await (await call("admin/request-indexers/adapters", owner.accessToken)).json();
    assert.equal(
      removed.adapters.some((item) => item.type === type),
      false,
    );
  } finally {
    if (installed) await call(`admin/request-indexers/plugins/${type}`, owner.accessToken, undefined, "DELETE");
    await call("auth/logout", null, { refreshToken: operator.refreshToken });
    await call("auth/logout", null, { refreshToken: owner.refreshToken });
  }
});

test("IPAD-E03-REQUEST-ADMIN-07: source and client colors and source network profile persist and clear through validated public APIs", async () => {
  const operator = await login("ipad-settings-admin");
  const fixture = await startRequestAdminFixture({ port: 0 });
  const ids = [];
  try {
    const sourceResponse = await call("admin/request-indexers", operator.accessToken, {
      name: `E03 colored source ${Date.now()}`,
      adapterType: "torznab",
      baseUrl: `${fixture.origin}/torznab`,
      allowPrivateAddress: true,
      color: "teal",
      networkProfile: { resolvers: ["1.1.1.1", "8.8.8.8"] },
    });
    assert.equal(sourceResponse.status, 201);
    const source = await sourceResponse.json();
    ids.push(["admin/request-indexers", source.id]);
    assert.equal(source.color, "teal");
    assert.deepEqual(source.networkProfile, { resolvers: ["1.1.1.1", "8.8.8.8"] });
    assert.equal((await call(`admin/request-indexers/${source.id}`, operator.accessToken, { color: "cyan" }, "PUT")).status, 400);
    assert.equal(
      (await call(`admin/request-indexers/${source.id}`, operator.accessToken, { networkProfile: { resolvers: ["example.com"] } }, "PUT")).status,
      400,
    );
    assert.equal(
      (await call(`admin/request-indexers/${source.id}`, operator.accessToken, { networkProfile: { proxyUrl: "socks5://localhost:1080" } }, "PUT"))
        .status,
      400,
    );
    const clearedResponse = await call(`admin/request-indexers/${source.id}`, operator.accessToken, { color: null, networkProfile: null }, "PUT");
    assert.equal(clearedResponse.status, 200);
    const cleared = await clearedResponse.json();
    assert.equal(cleared.color, null);
    assert.equal(cleared.networkProfile, null);
    const clientResponse = await call("admin/download-clients", operator.accessToken, {
      name: `E03 colored client ${Date.now()}`,
      adapterType: "qbittorrent",
      baseUrl: fixture.origin,
      allowPrivateAddress: true,
      color: "orange",
      pathMappings: [{ remotePath: "/downloads", localPath: "/tmp" }],
    });
    assert.equal(clientResponse.status, 201);
    const client = await clientResponse.json();
    ids.push(["admin/download-clients", client.id]);
    assert.equal(client.color, "orange");
    const result = await call(`admin/download-clients/${client.id}`, operator.accessToken, { color: null }, "PUT");
    assert.equal(result.status, 200);
    assert.equal((await result.json()).color, null);
  } finally {
    for (const [path, id] of ids.reverse()) assert.equal((await call(`${path}/${id}`, operator.accessToken, undefined, "DELETE")).status, 204);
    await call("auth/logout", null, { refreshToken: operator.refreshToken });
    await fixture.close();
  }
});

test("IPAD-E03-REQUEST-ADMIN-08: Prowlarr sync persists managed sources, permissions, unavailable state and credentials", async () => {
  const operator = await login("ipad-settings-admin");
  const moderator = await login("ipad-request-moderator");
  const fixture = await startRequestAdminFixture({ port: 0 });
  let managerID;
  try {
    const response = await call("admin/request-indexer-managers", operator.accessToken, {
      name: `E03 manager ${Date.now()}`,
      type: "prowlarr",
      baseUrl: fixture.origin,
      credential: "fixture-prowlarr-key",
      allowPrivateAddress: true,
      color: "purple",
      networkProfile: { resolvers: ["1.1.1.1"] },
    });
    assert.equal(response.status, 201);
    const manager = await response.json();
    managerID = manager.id;
    assert.equal(manager.hasCredential, true);
    assert.equal(manager.credential, undefined);
    assert.equal(manager.color, "purple");
    assert.deepEqual(manager.networkProfile, { resolvers: ["1.1.1.1"] });
    assert.equal(manager.lastSyncOk, true);
    assert.equal(manager.sources.length, 1);
    const source = manager.sources[0];
    assert.equal(source.externalId, "42");
    assert.equal(source.name, "E03 managed source");
    assert.equal(source.available, true);
    assert.equal((await call(`admin/request-indexer-managers/${managerID}/sync`, moderator.accessToken, {})).status, 403);
    const testResponse = await call(`admin/request-indexer-managers/${managerID}/test`, operator.accessToken, {});
    assert.equal(testResponse.status, 200);
    const tested = await testResponse.json();
    assert.equal(tested.success, true);
    assert.equal(tested.sourceCount, 1);
    const syncResponse = await call(`admin/request-indexer-managers/${managerID}/sync`, operator.accessToken, {});
    assert.equal(syncResponse.status, 200);
    const sync = await syncResponse.json();
    assert.equal(sync.discovered, 1);
    assert.equal(sync.created, 0);
    assert.equal(sync.updated, 1);
    assert.equal(sync.unavailable, 0);
    assert.equal(sync.manager.sources.length, 1);
    assert.equal(sync.manager.sources[0].id, source.id);
    const persistedResponse = await call(`admin/request-indexer-managers/${managerID}`, operator.accessToken);
    assert.equal(persistedResponse.status, 200);
    const persisted = await persistedResponse.json();
    assert.equal(persisted.sources.length, 1);
    assert.equal(persisted.sources[0].id, source.id);
    assert.equal(persisted.sources[0].externalId, "42");
    assert.equal(persisted.sources[0].name, "E03 managed source");
    const disabled = await call(`admin/request-indexer-managers/${managerID}/sources/${source.id}`, operator.accessToken, { enabled: false }, "PUT");
    assert.equal(disabled.status, 200);
    assert.equal((await disabled.json()).sources.find((item) => item.id === source.id).enabled, false);
    await fetch(`${fixture.origin}/control?managerUnavailable=true`);
    const unavailableResponse = await call(`admin/request-indexer-managers/${managerID}/sync`, operator.accessToken, {});
    assert.equal(unavailableResponse.status, 200);
    const unavailable = await unavailableResponse.json();
    assert.equal(unavailable.discovered, 0);
    assert.equal(unavailable.created, 0);
    assert.equal(unavailable.updated, 0);
    assert.equal(unavailable.unavailable, 1);
    assert.equal(unavailable.manager.sources[0].id, source.id);
    assert.equal(unavailable.manager.sources[0].enabled, false);
    assert.equal(unavailable.manager.sources[0].available, false);
  } finally {
    if (managerID) assert.equal((await call(`admin/request-indexer-managers/${managerID}`, operator.accessToken, undefined, "DELETE")).status, 204);
    await call("auth/logout", null, { refreshToken: operator.refreshToken });
    await call("auth/logout", null, { refreshToken: moderator.refreshToken });
    await fixture.close();
  }
});

test("IPAD-E03-REQUEST-ADMIN-09: reconciliation removes an owned orphan and hardlink probe checks actual server paths", async () => {
  const operator = await login("ipad-settings-admin");
  const moderator = await login("ipad-request-moderator");
  const fixture = await startRequestAdminFixture({ port: 0 });
  let clientID;
  try {
    const response = await call("admin/download-clients", operator.accessToken, {
      name: `E03 reconciled client ${Date.now()}`,
      adapterType: "qbittorrent",
      baseUrl: fixture.origin,
      allowPrivateAddress: true,
      category: "bookorbit",
      pathMappings: [{ remotePath: "/downloads", localPath: process.env.IPAD_E03_DOWNLOAD_PATH ?? "/tmp" }],
    });
    assert.equal(response.status, 201);
    const client = await response.json();
    clientID = client.id;
    const probe = await call(`admin/download-clients/${clientID}/test-path-mapping`, operator.accessToken, { mappingId: client.pathMappings[0].id });
    assert.equal(probe.status, 200);
    const result = await probe.json();
    assert.equal(result.localPathExists, true);
    assert.equal(result.bookDockPathExists, true);
    assert.equal(result.hardlinkWorks, true);
    await fetch(`${fixture.origin}/control?orphan=true`);
    assert.equal((await call(`admin/download-clients/${clientID}/reconciliation`, moderator.accessToken)).status, 403);
    const inventoryResponse = await call(`admin/download-clients/${clientID}/reconciliation`, operator.accessToken);
    assert.equal(inventoryResponse.status, 200);
    const inventory = await inventoryResponse.json();
    assert.equal(inventory.supported, true);
    assert.equal(inventory.items.length, 1);
    assert.equal(inventory.items[0].trackedAttempt, null);
    const key = inventory.items[0].clientKey;
    assert.equal(
      (await call(`admin/download-clients/${clientID}/reconciliation/${key}`, moderator.accessToken, { deleteFiles: false }, "DELETE")).status,
      403,
    );
    assert.equal(
      (await call(`admin/download-clients/${clientID}/reconciliation/${key}`, operator.accessToken, { deleteFiles: false }, "DELETE")).status,
      204,
    );
    const after = await (await call(`admin/download-clients/${clientID}/reconciliation`, operator.accessToken)).json();
    assert.deepEqual(after.items, []);
  } finally {
    if (clientID) assert.equal((await call(`admin/download-clients/${clientID}`, operator.accessToken, undefined, "DELETE")).status, 204);
    await call("auth/logout", null, { refreshToken: operator.refreshToken });
    await call("auth/logout", null, { refreshToken: moderator.refreshToken });
    await fixture.close();
  }
});

async function uploadPluginSource(source, token) {
  const form = new FormData();
  form.append("file", new Blob([source], { type: "text/javascript" }), "controlled-signed.mjs");
  return fetch(`${base}/admin/request-indexers/plugins`, {
    method: "POST",
    headers: { Authorization: `Bearer ${token}` },
    body: form,
  });
}

test("IPAD-E03-REQUEST-ADMIN-10: a reviewed signed plugin update installs through public APIs and persists the current file digest", async () => {
  const owner = await login("ipad-owner");
  const operator = await login("ipad-settings-admin");
  const type = `e03-signed-${Date.now()}`;
  const fixture = createSignedRequestPluginUpdate({ origin: `https://e03-plugin-updates.invalid/${type}`, type });
  let installed = false;
  try {
    const registration = await call(`__fixtures/plugin-updates/${type}`, owner.accessToken, {
      source: fixture.updateSource,
      manifest: fixture.manifest,
    });
    assert.equal(registration.status, 201);
    assert.equal(
      (await call(`__fixtures/plugin-updates/${type}`, operator.accessToken, { source: fixture.updateSource, manifest: fixture.manifest })).status,
      403,
    );
    const initial = await uploadPluginSource(fixture.initialSource, owner.accessToken);
    assert.equal(initial.status, 201);
    assert.equal((await initial.json()).active, true);
    installed = true;
    assert.equal((await call(`admin/request-indexers/plugins/${type}/update/inspect`, operator.accessToken, {})).status, 403);
    assert.equal(
      (await call(`admin/request-indexers/plugins/${type}/update`, operator.accessToken, { sha256: fixture.manifest.sha256 })).status,
      403,
    );
    const check = await call("admin/request-indexers/plugins/updates/check", owner.accessToken, {});
    assert.equal(check.status, 200);
    assert.equal((await check.json()).updates.find((item) => item.type === type).state, "available");
    const reviewResponse = await call(`admin/request-indexers/plugins/${type}/update/inspect`, owner.accessToken, {});
    assert.equal(reviewResponse.status, 200);
    const review = await reviewResponse.json();
    assert.equal(review.verified, true);
    assert.equal(review.version, "1.1.0");
    assert.equal(review.currentVersion, "1.0.0");
    assert.equal(review.source, fixture.updateSource);
    assert.equal(review.sha256, fixture.manifest.sha256);
    assert.equal((await call(`admin/request-indexers/plugins/${type}/update`, owner.accessToken, { sha256: "b".repeat(64) })).status, 400);
    const apply = await call(`admin/request-indexers/plugins/${type}/update`, owner.accessToken, { sha256: review.sha256 });
    assert.equal(apply.status, 200);
    const applied = await apply.json();
    assert.equal(applied.state, "current");
    assert.equal(applied.currentVersion, "1.1.0");
    const persistedResponse = await call("admin/request-indexers/plugins/updates/check", owner.accessToken, {});
    assert.equal(persistedResponse.status, 200);
    const persisted = (await persistedResponse.json()).updates.find((item) => item.type === type);
    assert.equal(persisted.state, "current");
    assert.equal(persisted.currentVersion, "1.1.0");
    assert.equal(persisted.latestVersion, "1.1.0");
    assert.equal((await call(`admin/request-indexers/plugins/${type}/update`, owner.accessToken, { sha256: fixture.manifest.sha256 })).status, 400);
  } finally {
    if (installed) assert.equal((await call(`admin/request-indexers/plugins/${type}`, owner.accessToken, undefined, "DELETE")).status, 204);
    await call(`__fixtures/plugin-updates/${type}`, owner.accessToken, undefined, "DELETE");
    await call("auth/logout", null, { refreshToken: owner.refreshToken });
    await call("auth/logout", null, { refreshToken: operator.refreshToken });
  }
});

test("IPAD-E03-REQUEST-ADMIN-11: a forged signature is rejected even when the tampered source matches the manifest digest", async () => {
  const owner = await login("ipad-owner");
  const type = `e03-forged-${Date.now()}`;
  const fixture = createSignedRequestPluginUpdate({ origin: `https://e03-plugin-updates.invalid/${type}`, type });
  const tamperedSource = fixture.updateSource.replace("E03 signed plugin", "Forged publisher label");
  const tamperedManifest = { ...fixture.manifest, sha256: createHash("sha256").update(tamperedSource).digest("hex") };
  let installed = false;
  try {
    assert.equal(
      (await call(`__fixtures/plugin-updates/${type}`, owner.accessToken, { source: tamperedSource, manifest: tamperedManifest })).status,
      201,
    );
    const initial = await uploadPluginSource(fixture.initialSource, owner.accessToken);
    assert.equal(initial.status, 201);
    assert.equal((await initial.json()).active, true);
    installed = true;
    const review = await call(`admin/request-indexers/plugins/${type}/update/inspect`, owner.accessToken, {});
    assert.equal(review.status, 400);
    assert.match((await review.json()).message, /valid publisher signature/);
    const apply = await call(`admin/request-indexers/plugins/${type}/update`, owner.accessToken, { sha256: tamperedManifest.sha256 });
    assert.equal(apply.status, 400);
    assert.match((await apply.json()).message, /valid publisher signature/);
    const statusResponse = await call("admin/request-indexers/plugins/updates/check", owner.accessToken, {});
    assert.equal(statusResponse.status, 200);
    const status = (await statusResponse.json()).updates.find((item) => item.type === type);
    assert.equal(status.currentVersion, "1.0.0");
    assert.equal(status.latestVersion, "1.1.0");
    assert.equal(status.state, "available");
  } finally {
    if (installed) assert.equal((await call(`admin/request-indexers/plugins/${type}`, owner.accessToken, undefined, "DELETE")).status, 204);
    await call(`__fixtures/plugin-updates/${type}`, owner.accessToken, undefined, "DELETE");
    await call("auth/logout", null, { refreshToken: owner.refreshToken });
  }
});

test("IPAD-E03-REQUEST-ADMIN-12: the controlled update provider still refuses a manifest that points at a private source address", async () => {
  const owner = await login("ipad-owner");
  const type = `e03-private-${Date.now()}`;
  const fixture = createSignedRequestPluginUpdate({ origin: `https://e03-plugin-updates.invalid/${type}`, type });
  const manifest = { ...fixture.manifest, sourceUrl: "https://127.0.0.1:16502/index.mjs" };
  let installed = false;
  try {
    assert.equal((await call(`__fixtures/plugin-updates/${type}`, owner.accessToken, { source: fixture.updateSource, manifest })).status, 201);
    const initial = await uploadPluginSource(fixture.initialSource, owner.accessToken);
    assert.equal(initial.status, 201);
    assert.equal((await initial.json()).active, true);
    installed = true;
    const review = await call(`admin/request-indexers/plugins/${type}/update/inspect`, owner.accessToken, {});
    assert.equal(review.status, 400);
    assert.match((await review.json()).message, /private or local address/);
    const statusResponse = await call("admin/request-indexers/plugins/updates/check", owner.accessToken, {});
    assert.equal(statusResponse.status, 200);
    assert.equal((await statusResponse.json()).updates.find((item) => item.type === type).currentVersion, "1.0.0");
  } finally {
    if (installed) assert.equal((await call(`admin/request-indexers/plugins/${type}`, owner.accessToken, undefined, "DELETE")).status, 204);
    await call(`__fixtures/plugin-updates/${type}`, owner.accessToken, undefined, "DELETE");
    await call("auth/logout", null, { refreshToken: owner.refreshToken });
  }
});
