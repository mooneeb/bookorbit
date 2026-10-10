import { test } from "node:test";
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { createHash } from "node:crypto";

const base = "http://localhost:16482/api/v1";
async function request(path, token, method = "GET", body) {
  return fetch(`${base}/${path}`, {
    method,
    headers: { ...(token ? { Authorization: `Bearer ${token}` } : {}), ...(body ? { "Content-Type": "application/json" } : {}) },
    ...(body ? { body: JSON.stringify(body) } : {}),
  });
}
async function login(username) {
  const response = await request("auth/login", null, "POST", {
    username,
    password: "IpadFixture123",
    clientKind: "native",
    deviceLabel: "Recovery snapshot fixture",
  });
  assert.equal(response.status, 200);
  return (await response.json()).accessToken;
}
async function apply(token, operation) {
  const response = await request("annotations/native/operations", token, "POST", { deviceId: "recovery-snapshot-http", operations: [operation] });
  assert.equal(response.status, 201);
  return (await response.json()).results[0];
}
test("IPAD-E02-A05/A06-http: a partial stale edit exports its retained base drawing and explicitly attaches as a new identity", async () => {
  const token = await login("ipad-reader");
  const clientId = randomUUID();
  const drawing = {
    format: "bookorbit-ink-v1",
    nativeData: "AQID",
    strokes: [
      {
        id: "original-stroke",
        points: [
          { x: 12, y: 18 },
          { x: 22, y: 30 },
        ],
        color: "#112233",
        width: 1.5,
      },
    ],
  };
  const created = await apply(token, {
    operationId: randomUUID(),
    clientId,
    bookId: 1,
    baseVersion: 0,
    action: "create",
    payload: { cfi: "epubcfi(/6/2!/4/2:0)", text: "retained original passage", note: "original note", kind: "handwriting", drawing },
  });
  assert.equal(created.status, "applied");
  const newer = await apply(token, {
    operationId: randomUUID(),
    clientId,
    annotationId: created.annotation.id,
    bookId: 1,
    baseVersion: 1,
    action: "update",
    payload: {
      text: "newer canonical passage",
      note: "newer canonical note",
      drawing: { ...drawing, nativeData: "BAUG", strokes: [{ ...drawing.strokes[0], id: "newer-stroke" }] },
    },
  });
  assert.equal(newer.status, "applied");
  await apply(token, { operationId: randomUUID(), clientId, annotationId: created.annotation.id, bookId: 1, baseVersion: 2, action: "delete" });
  const operationId = randomUUID();
  const stale = await apply(token, {
    operationId,
    clientId,
    annotationId: created.annotation.id,
    bookId: 1,
    baseVersion: 1,
    action: "update",
    payload: { note: "offline intended note" },
  });
  assert.equal(stale.status, "recovery");
  const response = await request("annotations/native/hub/drafts?bookId=1&limit=100", token);
  assert.equal(response.status, 200);
  const draft = (await response.json()).items.find((item) => item.operationId === operationId);
  assert.equal(draft.snapshot?.kind, "handwriting");
  assert.equal(draft.snapshot.text, "retained original passage");
  assert.equal(draft.snapshot.note, "offline intended note");
  assert.deepEqual(draft.snapshot.drawing, drawing);
  assert.equal(draft.payload.baseVersion, 1);
  const staleDelete = await apply(token, {
    operationId: randomUUID(),
    clientId,
    annotationId: created.annotation.id,
    bookId: 1,
    baseVersion: 1,
    action: "delete",
  });
  assert.equal(staleDelete.status, "recovery");
  assert.equal(staleDelete.recoverySnapshot.kind, "handwriting");
  assert.equal(staleDelete.recoverySnapshot.note, "original note");
  assert.deepEqual(staleDelete.recoverySnapshot.drawing, drawing);
  const newClientId = randomUUID();
  const attached = await apply(token, {
    operationId: randomUUID(),
    clientId: newClientId,
    bookId: 1,
    baseVersion: 0,
    action: "create",
    payload: {
      cfi: "epubcfi(/6/2!/4/4:0)",
      text: draft.snapshot.text,
      note: draft.snapshot.note,
      kind: draft.snapshot.kind,
      drawing: draft.snapshot.drawing,
    },
  });
  assert.equal(attached.status, "applied");
  assert.notEqual(attached.annotation.id, created.annotation.id);
  const delta = await request("annotations/native/delta?bookId=1&cursor=0&limit=100", token);
  assert.ok((await delta.json()).items.find((item) => item.id === created.annotation.id).deletedAt);
  const exportResponse = await request(`annotations/native/hub/export?ids=${attached.annotation.id}`, token);
  assert.equal(exportResponse.status, 200);
  const exported = await exportResponse.json();
  assert.deepEqual(exported.items[0].drawing, drawing);
});

test("IPAD-E02-A06-http: private PDF repair needs matching source proof and preserves the original on a replacement race", async () => {
  const token = await login("ipad-reader");
  const clientId = randomUUID();
  const rect = { x: 50, y: 90, width: 190, height: 24 };
  const created = await apply(token, {
    operationId: randomUUID(),
    clientId,
    bookId: 1,
    baseVersion: 0,
    action: "create",
    payload: {
      bookFileId: 1,
      pdf: { page: 0, rect, rects: [rect] },
      text: "Orbit fixture passage",
      note: "private repaired note",
      kind: "text_note",
    },
  });
  assert.equal(created.status, "applied");
  const sourceResponse = await request("annotations/native/files/1/source?bookId=1&page=1", token);
  assert.equal(sourceResponse.status, 200);
  const source = await sourceResponse.json();
  assert.equal(source.canEditPdfInk, false);
  const repaired = await apply(token, {
    operationId: randomUUID(),
    clientId,
    annotationId: created.annotation.id,
    bookId: 1,
    baseVersion: 1,
    action: "repair",
    payload: { bookFileId: 1, pdf: { page: 1, rect, rects: [rect] }, sourceRevision: source.sourceRevision, pageFingerprint: source.pageFingerprint },
  });
  assert.equal(repaired.status, "applied");
  assert.equal(repaired.annotation.pdf.page, 1);
  assert.equal(repaired.annotation.note, "private repaired note");
  assert.equal(repaired.publication, undefined);
  const raced = await apply(token, {
    operationId: randomUUID(),
    clientId,
    annotationId: created.annotation.id,
    bookId: 1,
    baseVersion: 2,
    action: "repair",
    payload: {
      bookFileId: 1,
      pdf: { page: 1, rect: { ...rect, x: 80 }, rects: [{ ...rect, x: 80 }] },
      sourceRevision: `sha256:${"0".repeat(64)}`,
      pageFingerprint: source.pageFingerprint,
    },
  });
  assert.equal(raced.status, "recovery");
  assert.equal(raced.annotation.version, 2);
  assert.equal(raced.annotation.pdf.rect.x, 50);
  const draftResponse = await request("annotations/native/hub/drafts?bookId=1&limit=100", token);
  const draft = (await draftResponse.json()).items.find((item) => item.id === raced.draftId);
  assert.equal(draft.reason, "source_revision_changed");
  const previewResponse = await request("annotations/native/files/1/source?bookId=1&page=0", token);
  assert.equal(previewResponse.status, 200);
  const preview = await previewResponse.json();
  const owner = await login("ipad-owner");
  const deliveredBefore = await request("books/files/1/serve", token);
  assert.equal(deliveredBefore.status, 200);
  const originalHash = createHash("sha256")
    .update(Buffer.from(await deliveredBefore.arrayBuffer()))
    .digest("hex");
  try {
    const replacement = await request("__faults/source-pdf/source/1/replace", owner, "POST");
    assert.equal(replacement.status, 204);
    const replacedBytes = await request("books/files/1/serve", token);
    assert.equal(replacedBytes.status, 200);
    assert.notEqual(
      createHash("sha256")
        .update(Buffer.from(await replacedBytes.arrayBuffer()))
        .digest("hex"),
      originalHash,
    );
    const changed = await apply(token, {
      operationId: randomUUID(),
      clientId,
      annotationId: created.annotation.id,
      bookId: 1,
      baseVersion: 2,
      action: "repair",
      payload: {
        bookFileId: 1,
        pdf: { page: 0, rect: { ...rect, x: 120 }, rects: [{ ...rect, x: 120 }] },
        sourceRevision: preview.sourceRevision,
        pageFingerprint: preview.pageFingerprint,
      },
    });
    assert.equal(changed.status, "recovery");
    assert.equal(changed.annotation.version, 2);
    assert.equal(changed.annotation.pdf.page, 1);
    assert.equal(changed.annotation.pdf.rect.x, 50);
    assert.equal(changed.recoverySnapshot.kind, "text_note");
    assert.equal(changed.recoverySnapshot.note, "private repaired note");
  } finally {
    assert.equal((await request("__faults/source-pdf/source/1/restore", owner, "POST")).status, 204);
    const restoredBytes = await request("books/files/1/serve", token);
    assert.equal(restoredBytes.status, 200);
    assert.equal(
      createHash("sha256")
        .update(Buffer.from(await restoredBytes.arrayBuffer()))
        .digest("hex"),
      originalHash,
    );
  }
});

test("IPAD-E02-A05-http: missing retained history remains explicit and exports the original partial operation", async () => {
  const token = await login("ipad-reader");
  const marker = `missing-base-${randomUUID()}`;
  const response = await request("books/1/annotations", token, "POST", {
    cfi: "epubcfi(/6/2!/4/2:0)",
    text: "legacy passage",
    note: "legacy original note",
  });
  assert.equal(response.status, 201);
  const original = await response.json();
  const clientId = randomUUID();
  const newer = await apply(token, {
    operationId: randomUUID(),
    clientId,
    annotationId: original.id,
    bookId: 1,
    baseVersion: 1,
    action: "update",
    payload: { note: "newer canonical legacy note" },
  });
  assert.equal(newer.status, "applied");
  const operation = {
    operationId: randomUUID(),
    clientId,
    annotationId: original.id,
    bookId: 1,
    baseVersion: 1,
    action: "update",
    payload: { note: marker },
  };
  const stale = await apply(token, operation);
  assert.equal(stale.status, "conflict");
  assert.equal(stale.recoverySnapshot, undefined);
  assert.equal(stale.recoverySnapshotUnavailableReason, "retained_base_unavailable");
  const draftsResponse = await request(`annotations/native/hub/drafts?bookId=1&search=${marker}&limit=1`, token);
  assert.equal(draftsResponse.status, 200);
  const draft = (await draftsResponse.json()).items[0];
  assert.equal(draft.snapshot, undefined);
  assert.equal(draft.snapshotUnavailableReason, "retained_base_unavailable");
  assert.deepEqual(draft.payload, operation);
  const exportedResponse = await request(`annotations/native/hub/export?status=recovery&search=${marker}&limit=1`, token);
  assert.equal(exportedResponse.status, 200);
  assert.deepEqual((await exportedResponse.json()).drafts[0].payload, operation);
  const other = await login("ipad-owner");
  const foreign = await request(`annotations/native/hub/drafts?bookId=1&search=${marker}&limit=1`, other);
  assert.equal(foreign.status, 200);
  assert.deepEqual((await foreign.json()).items, []);
});
