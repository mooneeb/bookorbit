import { test } from "node:test";
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";

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
    deviceLabel: "Annotation HTTP fixture",
  });
  assert.equal(response.status, 200);
  return (await response.json()).accessToken;
}
test("IPAD-E02-A01/A05-http: retained handwriting survives retries and stale deletion edits become recovery drafts", async () => {
  const token = await login("ipad-reader");
  const other = await login("ipad-owner");
  assert.equal((await request("annotations/native/delta?bookId=1")).status, 401);
  const operation = {
    operationId: randomUUID(),
    clientId: randomUUID(),
    bookId: 1,
    baseVersion: 0,
    action: "create",
    payload: {
      cfi: "epubcfi(/6/2!/4/2:0)",
      text: "Orbit passage",
      note: "searchable English Scribble",
      kind: "handwriting",
      drawing: {
        format: "bookorbit-ink-v1",
        nativeData: "AQID",
        strokes: [
          {
            id: "stroke-1",
            points: [
              { x: 10, y: 20, pressure: 0.5 },
              { x: 15, y: 25 },
            ],
            color: "#112233",
            width: 1.5,
          },
        ],
      },
    },
  };
  const batch = { deviceId: "http-native", operations: [operation] };
  const createdResponse = await request("annotations/native/operations", token, "POST", batch);
  assert.equal(createdResponse.status, 201);
  const created = (await createdResponse.json()).results[0];
  assert.equal(created.status, "applied");
  assert.deepEqual(created.annotation.drawing, operation.payload.drawing);
  const retry = await request("annotations/native/operations", token, "POST", batch);
  assert.deepEqual((await retry.json()).results[0], created);
  const foreign = await request("annotations/native/operations", other, "POST", {
    deviceId: "foreign",
    operations: [
      { ...operation, operationId: randomUUID(), annotationId: created.annotation.id, action: "delete", baseVersion: 1, payload: undefined },
    ],
  });
  assert.equal(foreign.status, 403);
  const deletion = {
    ...operation,
    operationId: randomUUID(),
    annotationId: created.annotation.id,
    action: "delete",
    baseVersion: 1,
    payload: undefined,
  };
  const removed = await request("annotations/native/operations", token, "POST", { deviceId: "web", operations: [deletion] });
  assert.equal(removed.status, 201);
  assert.equal((await removed.json()).results[0].annotation.version, 2);
  const stale = await request("annotations/native/operations", token, "POST", {
    deviceId: "offline-native",
    operations: [
      {
        ...operation,
        operationId: randomUUID(),
        annotationId: created.annotation.id,
        action: "update",
        baseVersion: 1,
        payload: { note: "retained stale draft" },
      },
    ],
  });
  const staleResult = (await stale.json()).results[0];
  assert.equal(staleResult.status, "recovery");
  assert.ok(staleResult.draftId > 0);
  const delta = await request("annotations/native/delta?bookId=1&cursor=0&limit=100", token);
  const changes = await delta.json();
  assert.ok(changes.items.find((item) => item.id === created.annotation.id).deletedAt);
  const web = await request("books/1/annotations?page=1&pageSize=100", token);
  assert.ok(!(await web.json()).items.some((item) => item.id === created.annotation.id));
});
