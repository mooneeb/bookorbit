import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { createHash, randomUUID } from "node:crypto";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { createRequire } from "node:module";
import { resolve } from "node:path";
import { test } from "node:test";
import { promisify } from "node:util";

const require = createRequire(new URL("../../server/package.json", import.meta.url));
const { PDFDocument, PDFDict, PDFHexString, PDFName, PDFNumber } = require("pdf-lib");
const sharp = require("sharp");
const execute = promisify(execFile);
const artifactDirectory = resolve("test-results/ipad", process.env.IPAD_TEST_RUN ?? "source-ink-http", "shared-source-pdf");
const base = process.env.IPAD_SOURCE_INK_API_URL ?? "http://localhost:16482/api/v1";
const listRoute = "annotations/native/source-ink?bookId=1&bookFileId=1&cursor=0&limit=100";
const operationsRoute = "annotations/native/source-ink/1/1/operations";

async function request(path, token, body, method = body ? "POST" : "GET") {
  return fetch(`${base}/${path}`, {
    method,
    headers: {
      ...(token ? { Authorization: `Bearer ${token}` } : {}),
      ...(body ? { "Content-Type": "application/json" } : {}),
    },
    ...(body ? { body: JSON.stringify(body) } : {}),
  });
}

async function json(response, status = 200) {
  assert.equal(response.status, status, await response.clone().text());
  return response.json();
}

async function login(username) {
  return (
    await json(
      await request("auth/login", null, {
        username,
        password: "IpadFixture123",
        clientKind: "native",
        deviceLabel: "Shared source ink HTTP fixture",
      }),
    )
  ).accessToken;
}

async function source(token) {
  return json(await request("annotations/native/files/1/source?bookId=1&page=0", token));
}

async function mutateHttp(token, operation) {
  return (
    await json(
      await request(operationsRoute, token, {
        deviceId: "shared-source-http",
        operations: [operation],
      }),
      201,
    )
  ).results[0];
}

async function delivered(token) {
  const response = await request("books/files/1/serve", token);
  assert.equal(response.status, 200);
  return Buffer.from(await response.arrayBuffer());
}

async function deliveredIds(token, bytes = null) {
  const document = await PDFDocument.load(bytes ?? (await delivered(token)));
  return document.getPages().flatMap((page) =>
    (page.node.Annots()?.asArray() ?? []).flatMap((ref) => {
      const item = document.context.lookup(ref);
      if (!(item instanceof PDFDict)) return [];
      const id = item.lookupMaybe(PDFName.of("BookOrbitAnnotationId"), PDFNumber)?.asNumber();
      return id == null ? [] : [id];
    }),
  );
}

async function rendered(token, name, bytes = null) {
  await mkdir(artifactDirectory, { recursive: true });
  bytes ??= await delivered(token);
  const path = resolve(artifactDirectory, `${name}.pdf`);
  const imagePath = resolve(artifactDirectory, name);
  await writeFile(path, bytes);
  await execute("/opt/homebrew/bin/pdftoppm", ["-f", "1", "-singlefile", "-scale-to-x", "600", "-scale-to-y", "800", "-png", path, imagePath]);
  const text = await execute("/opt/homebrew/bin/pdftotext", [path, "-"]);
  for (const passage of [1, 2, 3]) assert.match(text.stdout, new RegExp(`Orbit fixture: passage ${passage}`));
  return sharp(await readFile(`${imagePath}.png`))
    .removeAlpha()
    .raw()
    .toBuffer({ resolveWithObject: true });
}

function pixel(image, x, y) {
  const offset = (y * image.info.width + x) * image.info.channels;
  return [...image.data.subarray(offset, offset + 3)];
}

function blankOffset(image, segments) {
  for (let offset = -100; offset <= 100; offset += 10) {
    if (
      segments.every(([left, right, y]) => {
        for (let row = y + offset - 5; row <= y + offset + 5; row++) {
          for (let x = left - 5; x <= right + 5; x++) {
            if (!pixel(image, x, row).every((channel) => channel === 255)) return false;
          }
        }
        return true;
      })
    )
      return offset;
  }
  assert.fail("fixture must provide a blank region for independently visible test ink");
}

const hash = (bytes) => createHash("sha256").update(bytes).digest("hex");

test("IPAD-E02-A03-source-sharing: library readers see shared ink, authorized other-account edits preserve privacy and revisioned Undo", async (t) => {
  const owner = await login("ipad-owner");
  const reader = await login("ipad-reader");
  const editor = await login("ipad-editor");
  const restricted = await login("ipad-restricted");
  const before = await delivered(owner);
  const baselineDocument = await PDFDocument.load(before);
  const baselineIds = await deliveredIds(owner, before);
  const baselineImage = await rendered(owner, "baseline-shared-ink", before);
  const offset = blankOffset(baselineImage, [
    [80, 180, 600],
    [200, 300, 600],
    [350, 450, 650],
  ]);
  const tracked = new Map();
  assert.equal((await request("__faults/source-pdf/source/1/snapshot", owner, null, "POST")).status, 204);
  const mutate = async (token, operation) => {
    const result = await mutateHttp(token, operation);
    if (result.annotation && result.status === "applied") tracked.set(result.annotation.id, result.annotation);
    return result;
  };
  t.after(async () => {
    try {
      for (const annotation of tracked.values()) {
        if (annotation.deletedAt) continue;
        const current = await source(owner);
        const result = await mutateHttp(owner, {
          operationId: randomUUID(),
          clientId: annotation.clientId,
          annotationId: annotation.id,
          bookId: 1,
          baseVersion: annotation.version,
          action: "delete",
          payload: { sourceRevision: current.sourceRevision, pageFingerprint: current.pageFingerprint },
        });
        assert.equal(result.status, "applied");
        assert.equal(result.publication.status, "published");
      }
      const after = await delivered(owner);
      assert.deepEqual(await deliveredIds(owner, after), baselineIds, "unrelated source ink IDs remain intact");
      const document = await PDFDocument.load(after);
      assert.deepEqual(
        document.getPages().map((page) => page.getSize()),
        baselineDocument.getPages().map((page) => page.getSize()),
      );
      const cleanedImage = await rendered(owner, "cleanup-delivered", after);
      assert.equal(hash(cleanedImage.data), hash(baselineImage.data), "cleanup preserves all unrelated visible PDF content");
    } finally {
      assert.equal((await request("__faults/source-pdf/source/1/restore", owner, null, "POST")).status, 204);
      assert.equal(hash(await delivered(owner)), hash(before), "finally restores the exact baseline source SHA");
    }
  });
  await json(await request(listRoute, reader));
  assert.equal((await request(listRoute)).status, 401);
  assert.equal((await request(listRoute, restricted)).status, 404);

  const privateOperation = {
    operationId: randomUUID(),
    clientId: randomUUID(),
    bookId: 1,
    baseVersion: 0,
    action: "create",
    payload: { cfi: "epubcfi(/6/2!/4/2:0)", kind: "text_note", text: "private passage", note: "private owner text" },
  };
  const privateResult = (
    await json(
      await request("annotations/native/operations", owner, {
        deviceId: "private-source-fixture",
        operations: [privateOperation],
      }),
      201,
    )
  ).results[0];
  t.after(async () => {
    const response = await json(
      await request("annotations/native/operations", owner, {
        deviceId: "private-source-fixture",
        operations: [
          {
            operationId: randomUUID(),
            clientId: privateOperation.clientId,
            annotationId: privateResult.annotation.id,
            bookId: 1,
            baseVersion: privateResult.annotation.version,
            action: "delete",
          },
        ],
      }),
      201,
    );
    assert.equal(response.results[0].status, "applied");
  });
  assert.equal(privateResult.status, "applied");

  const initial = await source(owner);
  const create = {
    operationId: randomUUID(),
    clientId: randomUUID(),
    bookId: 1,
    baseVersion: 0,
    action: "create",
    payload: {
      kind: "pdf_ink",
      bookFileId: 1,
      pdf: { page: 0, rect: { x: 0.1, y: 0.1, width: 0.2, height: 0.2 }, rects: [] },
      drawing: {
        format: "bookorbit-ink-v1",
        strokes: [
          {
            id: "shared-stroke",
            points: [
              { x: 80, y: 600 + offset },
              { x: 180, y: 600 + offset },
            ],
            color: "#ff0000",
            width: 8,
          },
        ],
      },
      sourceRevision: initial.sourceRevision,
      pageFingerprint: initial.pageFingerprint,
    },
  };
  const created = await mutate(owner, create);
  assert.equal(created.status, "applied");
  assert.equal(created.publication.status, "published");
  const unrelated = await mutate(owner, {
    ...create,
    operationId: randomUUID(),
    clientId: randomUUID(),
    payload: {
      ...create.payload,
      sourceRevision: created.publication.sourceRevision,
      drawing: {
        format: "bookorbit-ink-v1",
        strokes: [
          {
            id: "unrelated",
            points: [
              { x: 350, y: 650 + offset },
              { x: 450, y: 650 + offset },
            ],
            color: "#00ff00",
            width: 8,
          },
        ],
      },
    },
  });
  assert.equal(unrelated.publication.status, "published");
  const initialImage = await rendered(owner, "owner-created");
  assert.deepEqual(pixel(initialImage, 130, 600 + offset), [255, 0, 0]);
  const shared = await json(await request(listRoute, reader));
  assert.deepEqual(shared.items.find((item) => item.id === created.annotation.id)?.drawing, create.payload.drawing);
  assert.equal(
    shared.items.some((item) => item.id === privateResult.annotation.id),
    false,
  );
  assert.equal(
    shared.items.every((item) => item.kind === "pdf_ink" && item.jumpFileId === 1),
    true,
  );
  const page = await json(await request(`${listRoute}&page=1`, reader));
  assert.equal(
    page.items.some((item) => item.id === created.annotation.id),
    false,
  );
  const privateDelta = await json(await request("annotations/native/delta?bookId=1&cursor=0&limit=100", editor));
  assert.equal(
    privateDelta.items.some((item) => item.id === created.annotation.id),
    false,
  );

  const movedPdf = { page: 0, rect: { x: 0.2, y: 0.2, width: 0.2, height: 0.2 }, rects: [] };
  const moved = await mutate(editor, {
    operationId: randomUUID(),
    clientId: create.clientId,
    annotationId: created.annotation.id,
    bookId: 1,
    baseVersion: created.annotation.version,
    action: "update",
    payload: {
      pdf: movedPdf,
      drawing: {
        format: "bookorbit-ink-v1",
        strokes: [
          {
            id: "shared-stroke",
            points: [
              { x: 200, y: 600 + offset },
              { x: 300, y: 600 + offset },
            ],
            color: "#0000ff",
            width: 8,
          },
        ],
      },
    },
  });
  assert.equal(moved.status, "applied");
  assert.equal(moved.publication?.status, "published", JSON.stringify(moved.publication));
  assert.equal(moved.annotation.version, 2);
  assert.equal(moved.annotation.id, created.annotation.id);
  assert.equal(moved.annotation.jumpFileId, 1);
  assert.deepEqual(moved.annotation.pdf, movedPdf);
  assert.equal(moved.annotation.createdAt, created.annotation.createdAt);
  assert.equal(moved.annotation.clientId, created.annotation.clientId);
  const movedDelta = await json(await request(listRoute, reader));
  assert.deepEqual(movedDelta.items.find((item) => item.id === created.annotation.id)?.pdf, movedPdf);
  const movedImage = await rendered(owner, "editor-moved");
  assert.deepEqual(pixel(movedImage, 130, 600 + offset), [255, 255, 255]);
  assert.deepEqual(pixel(movedImage, 250, 600 + offset), [0, 0, 255]);
  const movedDocument = await PDFDocument.load(await delivered(owner));
  const movedDictionary = movedDocument
    .getPage(0)
    .node.Annots()
    .asArray()
    .map((ref) => movedDocument.context.lookup(ref))
    .find(
      (item) => item instanceof PDFDict && item.lookupMaybe(PDFName.of("BookOrbitAnnotationId"), PDFNumber)?.asNumber() === created.annotation.id,
    );
  assert.equal(movedDictionary.lookupMaybe(PDFName.of("BookOrbitUserId"), PDFNumber)?.asNumber(), 1);
  assert.deepEqual(JSON.parse(movedDictionary.lookupMaybe(PDFName.of("BookOrbitDrawing"), PDFHexString).decodeText()), moved.annotation.drawing);

  const deletion = {
    operationId: randomUUID(),
    clientId: create.clientId,
    annotationId: created.annotation.id,
    bookId: 1,
    baseVersion: moved.annotation.version,
    action: "delete",
  };
  const deniedBefore = hash(await delivered(owner));
  assert.equal((await request(operationsRoute, reader, { deviceId: "read-only", operations: [deletion] })).status, 403);
  assert.equal((await request(operationsRoute, restricted, { deviceId: "restricted", operations: [deletion] })).status, 403);
  assert.equal((await request(listRoute, restricted)).status, 404);
  assert.equal(hash(await delivered(owner)), deniedBefore);
  assert.equal((await json(await request(listRoute, reader))).items.find((item) => item.id === created.annotation.id).version, 2);
  const removed = await mutate(editor, deletion);
  assert.equal(removed.status, "applied");
  assert.equal(removed.publication?.status, "published", JSON.stringify(removed.publication));
  assert.equal(removed.annotation.version, moved.annotation.version + 1);
  assert.ok(removed.annotation.deletedAt);
  assert.deepEqual(await mutate(editor, deletion), removed);
  assert.equal((await deliveredIds(owner)).includes(created.annotation.id), false);
  assert.equal((await deliveredIds(owner)).includes(unrelated.annotation.id), true);
  const deletedImage = await rendered(owner, "editor-deleted");
  assert.deepEqual(pixel(deletedImage, 250, 600 + offset), [255, 255, 255]);
  assert.deepEqual(pixel(deletedImage, 400, 650 + offset), [0, 255, 0]);
  const changes = await json(await request(`annotations/native/source-ink?bookId=1&bookFileId=1&cursor=${shared.nextCursor}&limit=100`, reader));
  assert.ok(changes.items.find((item) => item.id === created.annotation.id)?.deletedAt);

  const stale = await mutate(owner, { ...create, operationId: randomUUID(), annotationId: created.annotation.id, action: "update", baseVersion: 1 });
  assert.equal(stale.status, "recovery");
  assert.ok(stale.draftId > 0);
  assert.equal((await deliveredIds(owner)).includes(created.annotation.id), false);
  const currentSource = await source(editor);
  const restored = await mutate(editor, {
    ...deletion,
    operationId: randomUUID(),
    action: "restore",
    baseVersion: removed.annotation.version,
    payload: { sourceRevision: currentSource.sourceRevision, pageFingerprint: currentSource.pageFingerprint },
  });
  assert.equal(restored.status, "applied");
  assert.equal(restored.publication?.status, "published", JSON.stringify(restored.publication));
  assert.equal(restored.annotation.version, 4);
  assert.equal(restored.annotation.id, created.annotation.id);
  assert.equal(restored.annotation.deletedAt, null);
  assert.equal((await deliveredIds(owner)).includes(created.annotation.id), true);
  const restoredImage = await rendered(owner, "editor-restored");
  assert.deepEqual(pixel(restoredImage, 250, 600 + offset), [0, 0, 255]);
  assert.deepEqual(pixel(restoredImage, 400, 650 + offset), [0, 255, 0]);
  const beforeStaleInverse = hash(await delivered(owner));
  const inverseOfOldDelete = await mutate(owner, {
    ...deletion,
    operationId: randomUUID(),
    action: "restore",
    baseVersion: removed.annotation.version,
  });
  assert.equal(inverseOfOldDelete.status, "conflict");
  assert.equal(inverseOfOldDelete.annotation.version, restored.annotation.version);
  assert.equal(hash(await delivered(owner)), beforeStaleInverse);
  assert.equal(
    (
      await request(operationsRoute, editor, {
        deviceId: "private-forgery",
        operations: [{ ...deletion, operationId: randomUUID(), annotationId: privateResult.annotation.id }],
      })
    ).status,
    403,
  );
  const retainedPrivate = await json(await request("annotations/native/delta?bookId=1&cursor=0&limit=100", owner));
  assert.equal(retainedPrivate.items.find((item) => item.id === privateResult.annotation.id)?.note, "private owner text");
});
