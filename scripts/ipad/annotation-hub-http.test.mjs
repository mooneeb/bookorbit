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
    body: { username, password: "IpadFixture123", clientKind: "native", deviceLabel: "Annotation hub HTTP fixture" },
  });
  assert.equal(response.status, 200);
  return response.json();
}

async function record(path, token) {
  const response = await request(path, { token });
  assert.equal(response.status, 200, `${path}: ${await response.clone().text()}`);
  return response.json();
}

async function logout(session) {
  assert.equal((await request("auth/logout", { body: { refreshToken: session.refreshToken } })).status, 200);
}

test("IPAD-E02-A07-hub-bounds: authenticated hub validates bounded pages and strict request shapes", async () => {
  const owner = await login("ipad-owner");
  try {
    assert.equal((await request("annotations/native/hub")).status, 401);
    const page = await record("annotations/native/hub?limit=1", owner.accessToken);
    assert.ok(page.items.length <= 1);
    assert.ok(page.nextCursor === null || Number.isInteger(page.nextCursor));
    for (const query of ["limit=101", "limit=0", "cursor=-1", "kind=invalid", "groupBy=invalid", "status=invalid", "unexpected=true"]) {
      assert.equal((await request(`annotations/native/hub?${query}`, { token: owner.accessToken })).status, 400, query);
    }
  } finally {
    await logout(owner);
  }
});

test("IPAD-E02-A07-hub-search-export: text search, grouping, passage links and retained drawings stay user scoped", async () => {
  const reader = await login("ipad-reader");
  const owner = await login("ipad-owner");
  const marker = `hub-${randomUUID()}`;
  const rawMarker = `raw-${randomUUID()}`;
  const drawing = {
    format: "bookorbit-ink-v1",
    nativeData: rawMarker,
    strokes: [
      {
        id: "retained-stroke",
        points: [
          { x: 4, y: 8 },
          { x: 9, y: 12, pressure: 0.75 },
        ],
        color: "#112233",
        width: 2,
      },
    ],
  };
  try {
    const response = await request("annotations/native/operations", {
      token: reader.accessToken,
      body: {
        deviceId: "hub-http-native",
        operations: [
          {
            operationId: randomUUID(),
            clientId: randomUUID(),
            bookId: 2,
            baseVersion: 0,
            action: "create",
            payload: { cfi: "epubcfi(/6/2!/4/2:0)", text: marker, note: "Converted English Scribble", kind: "handwriting", drawing },
          },
          {
            operationId: randomUUID(),
            clientId: randomUUID(),
            bookId: 1,
            baseVersion: 0,
            action: "create",
            payload: { cfi: "epubcfi(/6/2!/4/4:0)", text: marker, kind: "highlight" },
          },
          {
            operationId: randomUUID(),
            clientId: randomUUID(),
            bookId: 2,
            baseVersion: 0,
            action: "create",
            payload: { cfi: "epubcfi(/6/2!/4/6:0)", text: marker, note: "Passage text note", kind: "text_note" },
          },
        ],
      },
    });
    assert.equal(response.status, 201, await response.clone().text());
    const created = (await response.json()).results.map((result) => result.annotation);
    const pages = [];
    let cursor;
    do {
      const page = await record(
        `annotations/native/hub?search=${marker}&groupBy=book&limit=1${cursor ? `&cursor=${cursor}` : ""}`,
        reader.accessToken,
      );
      assert.equal(page.items.length, 1);
      pages.push(...page.items);
      cursor = page.nextCursor;
    } while (cursor);
    assert.equal(pages.length, 3);
    assert.equal(new Set(pages.map((item) => item.id)).size, 3);
    assert.deepEqual(
      pages.map((item) => item.bookId),
      [1, 2, 2],
    );
    assert.ok(pages.every((item) => item.cfi && item.bookTitle && item.groupKey === String(item.bookId)));
    const handwritten = await record(`annotations/native/hub?search=${marker}&kind=handwriting`, reader.accessToken);
    assert.equal(handwritten.items.length, 1);
    assert.deepEqual(handwritten.items[0].drawing, drawing);
    assert.equal((await record(`annotations/native/hub?search=${rawMarker}`, reader.accessToken)).items.length, 0);
    assert.equal((await record(`annotations/native/hub?search=${marker}`, owner.accessToken)).items.length, 0);
    const exportResponse = await request(`annotations/native/hub/export?ids=${created.map((item) => item.id).join(",")}`, {
      token: reader.accessToken,
    });
    assert.equal(exportResponse.status, 200);
    assert.match(exportResponse.headers.get("content-disposition"), /attachment/);
    const artifact = await exportResponse.json();
    assert.equal(artifact.format, "bookorbit-annotations-v1");
    assert.equal(artifact.items.length, 3);
    assert.deepEqual(artifact.items.find((item) => item.kind === "handwriting").drawing, drawing);
    assert.equal((await request(`annotations/native/hub/export?ids=${created[0].id}`, { token: owner.accessToken })).status, 403);
  } finally {
    await logout(reader);
    await logout(owner);
  }
});

test("IPAD-E02-A05/A07-hub-recovery: explicit trash, restore and repair preserve stale work and acknowledgements", async () => {
  const reader = await login("ipad-reader");
  const owner = await login("ipad-owner");
  const marker = `hub-recovery-${randomUUID()}`;
  const clientId = randomUUID();
  async function operation(action, baseVersion, annotationId, payload, route = "annotations/native/operations") {
    const response = await request(route, {
      token: reader.accessToken,
      body: {
        deviceId: "hub-recovery-native",
        operations: [
          {
            operationId: randomUUID(),
            clientId,
            bookId: 2,
            baseVersion,
            action,
            ...(annotationId ? { annotationId } : {}),
            ...(payload ? { payload } : {}),
          },
        ],
      },
    });
    assert.equal(response.status, route === "annotations/native/operations" ? 201 : 200, await response.clone().text());
    return (await response.json()).results[0];
  }
  try {
    const created = (await operation("create", 0, undefined, { cfi: "epubcfi(/6/2!/4/2:0)", text: marker, note: "Original note", kind: "text_note" }))
      .annotation;
    const deleted = (await operation("delete", 1, created.id, undefined, "annotations/native/hub/bulk")).annotation;
    assert.ok(deleted.deletedAt);
    assert.equal((await record(`annotations/native/hub?search=${marker}`, reader.accessToken)).items.length, 0);
    assert.equal((await record(`annotations/native/hub?search=${marker}&status=trashed`, reader.accessToken)).items[0].id, created.id);
    const stale = await operation("update", 1, created.id, { text: marker, note: "Recoverable disconnected edit" });
    assert.equal(stale.status, "recovery");
    const drafts = await record(`annotations/native/hub/drafts?search=${marker}&limit=1`, reader.accessToken);
    assert.equal(drafts.items[0].reason, "annotation_deleted");
    assert.equal(drafts.items[0].payload.payload.note, "Recoverable disconnected edit");
    assert.equal((await record(`annotations/native/hub/drafts?search=${marker}`, owner.accessToken)).items.length, 0);
    const draftExport = await record(`annotations/native/hub/export?status=recovery&search=${marker}`, reader.accessToken);
    assert.equal(draftExport.drafts[0].payload.payload.note, "Recoverable disconnected edit");
    const restored = (await operation("restore", 2, created.id, undefined, "annotations/native/hub/bulk")).annotation;
    assert.equal(restored.deletedAt, null);
    assert.equal(restored.note, "Original note");
    const repaired = (await operation("repair", 3, created.id, { cfi: "epubcfi(/6/2!/4/4:0)" }, `annotations/native/hub/${created.id}/repair`))
      .annotation;
    assert.equal(repaired.cfi, "epubcfi(/6/2!/4/4:0)");
    assert.equal(repaired.positionStatus, "repaired");
    assert.equal((await record(`annotations/native/hub/drafts?search=${marker}`, reader.accessToken)).items.length, 1);
    const delta = await record("annotations/native/delta?bookId=2&limit=100", reader.accessToken);
    const ack = await request("annotations/native/ack", {
      token: reader.accessToken,
      body: { deviceId: "hub-recovery-native", bookId: 2, cursor: delta.nextCursor },
    });
    assert.equal(ack.status, 201);
    assert.ok((await record("annotations/native/hub/devices?bookId=2&limit=1", reader.accessToken)).items.length <= 1);
    const devices = await record("annotations/native/hub/devices?bookId=2&limit=100", reader.accessToken);
    assert.equal(devices.items.find((item) => item.deviceId === "hub-recovery-native").cursor, Number(delta.nextCursor));
    assert.ok(
      !(await record("annotations/native/hub/devices?bookId=2&limit=100", owner.accessToken)).items.some(
        (item) => item.deviceId === "hub-recovery-native",
      ),
    );
    assert.equal((await request("annotations/native/hub/devices?cursor=invalid", { token: reader.accessToken })).status, 400);
  } finally {
    await logout(reader);
    await logout(owner);
  }
});

test("IPAD-E02-A07-hub-permission: administrators can revoke own-annotation actions without granting source PDF writes", async () => {
  const owner = await login("ipad-owner");
  const restricted = await login("ipad-restricted");
  const reader = await login("ipad-reader");
  const original = [...restricted.user.permissions];
  const userId = restricted.user.id;
  try {
    assert.ok(original.includes("annotation_manage_own"));
    const sourceInk = await request("annotations/native/operations", {
      token: reader.accessToken,
      body: {
        deviceId: "hub-source-denied",
        operations: [
          {
            operationId: randomUUID(),
            clientId: randomUUID(),
            bookId: 1,
            baseVersion: 0,
            action: "create",
            payload: {
              kind: "pdf_ink",
              bookFileId: 1,
              text: "",
              pdf: { page: 0, rect: { x: 10, y: 10, width: 20, height: 20 }, rects: [{ x: 10, y: 10, width: 20, height: 20 }] },
              drawing: {
                format: "bookorbit-ink-v1",
                strokes: [
                  {
                    id: "denied",
                    points: [
                      { x: 10, y: 20 },
                      { x: 20, y: 30 },
                    ],
                    color: "#112233",
                    width: 2,
                  },
                ],
              },
            },
          },
        ],
      },
    });
    assert.equal(sourceInk.status, 403);
    const revoke = await request(`users/${userId}/permissions`, {
      token: owner.accessToken,
      method: "PUT",
      body: { permissionNames: original.filter((permission) => permission !== "annotation_manage_own") },
    });
    assert.equal(revoke.status, 204);
    assert.ok(!(await record("auth/me", restricted.accessToken)).permissions.includes("annotation_manage_own"));
    for (const path of ["annotations/native/hub/export", "annotations/native/hub/drafts", "annotations/native/hub/devices"]) {
      assert.equal((await request(path, { token: restricted.accessToken })).status, 403, path);
    }
    const mutation = {
      deviceId: "denied",
      operations: [{ operationId: randomUUID(), clientId: randomUUID(), bookId: 2, baseVersion: 0, action: "delete" }],
    };
    assert.equal((await request("annotations/native/hub/bulk", { token: restricted.accessToken, body: mutation })).status, 403);
    assert.equal((await request("annotations/native/hub/1/repair", { token: restricted.accessToken, body: mutation })).status, 403);
  } finally {
    const grant = await request(`users/${userId}/permissions`, { token: owner.accessToken, method: "PUT", body: { permissionNames: original } });
    assert.equal(grant.status, 204);
    await logout(restricted);
    await logout(reader);
    await logout(owner);
  }
});

test("IPAD-E02-A07-hub-compatibility: bounded mixed legacy and native mutations preserve public response shapes", async () => {
  const reader = await login("ipad-reader");
  const marker = `hub-compatibility-${randomUUID()}`;
  const token = reader.accessToken;
  let ids = [];
  async function bulk(action) {
    const response = await request("annotations/bulk", { token, body: { ids, action } });
    assert.equal(response.status, 200, await response.clone().text());
    return response.json();
  }
  try {
    const legacyResponse = await request("books/2/annotations", {
      token,
      body: { cfi: "epubcfi(/6/2!/4/2:0)", text: `${marker}-legacy`, note: "Legacy private note" },
    });
    assert.equal(legacyResponse.status, 201, await legacyResponse.clone().text());
    const legacy = await legacyResponse.json();
    const nativeResponse = await request("annotations/native/operations", {
      token,
      body: {
        deviceId: "hub-compatibility",
        operations: [
          {
            operationId: randomUUID(),
            clientId: randomUUID(),
            bookId: 2,
            baseVersion: 0,
            action: "create",
            payload: { cfi: "epubcfi(/6/2!/4/4:0)", text: `${marker}-native`, note: "Versioned private note", kind: "text_note" },
          },
        ],
      },
    });
    assert.equal(nativeResponse.status, 201, await nativeResponse.clone().text());
    const native = (await nativeResponse.json()).results[0].annotation;
    ids = [native.id, ...Array.from({ length: 100 }, (_, index) => 1_000_000_000 + index), legacy.id];
    assert.equal((await request("annotations/bulk", { body: { ids, action: "trash" } })).status, 401);
    assert.deepEqual(await bulk("trash"), { affected: 2 });
    const trashed = await record(`annotations/native/hub?search=${marker}&status=trashed`, token);
    assert.deepEqual(
      trashed.items.map((item) => item.id).sort((a, b) => a - b),
      [native.id, legacy.id].sort((a, b) => a - b),
    );
    assert.deepEqual(await bulk("restore"), { affected: 2 });
    assert.deepEqual(await bulk("trash"), { affected: 2 });
    for (const annotation of [legacy, native]) {
      const response = await request(`annotations/${annotation.id}/restore`, { token, method: "POST" });
      assert.equal(response.status, 200, await response.clone().text());
      const restored = await response.json();
      assert.equal(restored.id, annotation.id);
      assert.equal(restored.bookId, 2);
      assert.equal(restored.deletedAt, null);
      const retry = await request(`annotations/${annotation.id}/positions/retry`, { token, body: { format: "cfi" } });
      assert.equal(retry.status, 200, await retry.clone().text());
      assert.equal((await retry.json()).annotationId, annotation.id);
    }
  } finally {
    if (ids.length) await bulk("trash");
    await logout(reader);
  }
});
