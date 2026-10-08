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
const base = process.env.IPAD_PDF_INK_API_URL ?? "http://localhost:16482/api/v1";
const artifactDirectory = resolve("test-results/ipad", process.env.IPAD_TEST_RUN ?? "pdf-ink-http", "source-pdf");

async function request(path, token, body, method = body ? "POST" : "GET") {
  return fetch(`${base}/${path}`, {
    method,
    headers: { ...(token ? { Authorization: `Bearer ${token}` } : {}), ...(body ? { "Content-Type": "application/json" } : {}) },
    ...(body ? { body: JSON.stringify(body) } : {}),
  });
}
async function login(username) {
  const response = await request("auth/login", null, {
    username,
    password: "IpadFixture123",
    clientKind: "native",
    deviceLabel: "PDF artifact fixture",
  });
  assert.equal(response.status, 200);
  return response.json();
}
async function source(token) {
  const response = await request("annotations/native/files/1/source?bookId=1&page=0", token);
  assert.equal(response.status, 200, await response.clone().text());
  return response.json();
}
async function delivered(token) {
  const response = await request("books/files/1/serve", token);
  assert.equal(response.status, 200);
  return Buffer.from(await response.arrayBuffer());
}
async function operations(token, changes) {
  const response = await request("annotations/native/operations", token, { deviceId: "pdf-artifact-fixture", operations: changes });
  assert.equal(response.status, 201, await response.clone().text());
  return (await response.json()).results;
}
function items(document) {
  return document.getPages().flatMap((page) =>
    (page.node.Annots()?.asArray() ?? []).flatMap((reference) => {
      const annotation = document.context.lookup(reference);
      if (!(annotation instanceof PDFDict)) return [];
      const id = annotation.lookupMaybe(PDFName.of("BookOrbitAnnotationId"), PDFNumber)?.asNumber();
      if (id == null) return [];
      return [{ id, annotation, page }];
    }),
  );
}
async function rendered(bytes, name) {
  await mkdir(artifactDirectory, { recursive: true });
  const path = resolve(artifactDirectory, `${name}.pdf`);
  const imagePath = resolve(artifactDirectory, name);
  await writeFile(path, bytes);
  await execute("/opt/homebrew/bin/pdftoppm", ["-f", "1", "-singlefile", "-scale-to-x", "600", "-scale-to-y", "800", "-png", path, imagePath]);
  const image = await sharp(await readFile(`${imagePath}.png`))
    .removeAlpha()
    .raw()
    .toBuffer({ resolveWithObject: true });
  assert.equal(image.info.width, 600);
  assert.equal(image.info.height, 800);
  const text = await execute("/opt/homebrew/bin/pdftotext", [path, "-"]);
  assert.match(text.stdout, /Orbit fixture: passage 1/);
  assert.match(text.stdout, /Orbit fixture: passage 3/);
  return image;
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

async function isolatedOperations(t, token, before) {
  const baseline = await PDFDocument.load(before);
  const baselineIds = items(baseline)
    .map(({ id }) => id)
    .sort((a, b) => a - b);
  const tracked = new Map();
  assert.equal((await request("__faults/source-pdf/source/1/snapshot", token, null, "POST")).status, 204);
  t.after(async () => {
    try {
      for (const annotation of tracked.values()) {
        if (annotation.deletedAt) continue;
        const current = await source(token);
        const result = (
          await operations(token, [
            {
              operationId: randomUUID(),
              clientId: annotation.clientId,
              annotationId: annotation.id,
              bookId: 1,
              baseVersion: annotation.version,
              action: "delete",
              payload: { sourceRevision: current.sourceRevision, pageFingerprint: current.pageFingerprint },
            },
          ])
        )[0];
        assert.equal(result.status, "applied", "cleanup deletes only this test's own annotation");
        if (annotation.kind === "pdf_ink") assert.equal(result.publication.status, "published");
      }
      const after = await delivered(token);
      const document = await PDFDocument.load(after);
      assert.deepEqual(
        items(document)
          .map(({ id }) => id)
          .sort((a, b) => a - b),
        baselineIds,
        "unrelated source ink IDs remain intact",
      );
      assert.deepEqual(
        document.getPages().map((page) => page.getSize()),
        baseline.getPages().map((page) => page.getSize()),
      );
      const baselineImage = await rendered(before, "cleanup-baseline");
      const cleanedImage = await rendered(after, "cleanup-delivered");
      assert.equal(
        createHash("sha256").update(cleanedImage.data).digest("hex"),
        createHash("sha256").update(baselineImage.data).digest("hex"),
        "cleanup preserves all unrelated visible PDF content",
      );
    } finally {
      assert.equal((await request("__faults/source-pdf/source/1/restore", token, null, "POST")).status, 204);
      assert.equal(
        createHash("sha256")
          .update(await delivered(token))
          .digest("hex"),
        createHash("sha256").update(before).digest("hex"),
        "finally restores the exact baseline source SHA",
      );
    }
  });
  return async (changes) => {
    const results = await operations(token, changes);
    for (const result of results) if (result.annotation && result.status === "applied") tracked.set(result.annotation.id, result.annotation);
    return results;
  };
}

test("IPAD-E02-A02/A03/A06-PDF: delivered grouped source ink retains identity, renders independently, excludes private notes, and publishes versioned delete/restore", async (t) => {
  const owner = await login("ipad-owner");
  const reader = await login("ipad-reader");
  const token = owner.accessToken;
  const before = await delivered(token);
  const apply = await isolatedOperations(t, token, before);
  const baselineImage = await rendered(before, "baseline-grouped-ink");
  const offset = blankOffset(baselineImage, [
    [80, 180, 200],
    [80, 180, 230],
    [250, 350, 200],
    [400, 500, 300],
  ]);
  const initial = await source(token);
  assert.equal(initial.page, 0);
  assert.equal(initial.width, 600);
  assert.equal(initial.height, 800);
  assert.equal(initial.canEditPdfInk, true);
  assert.equal((await source(reader.accessToken)).canEditPdfInk, false);
  const privateText = `PRIVATE-PASSAGE-${randomUUID()}`;
  const privateOperation = {
    operationId: randomUUID(),
    clientId: randomUUID(),
    bookId: 1,
    baseVersion: 0,
    action: "create",
    payload: {
      kind: "text_note",
      bookFileId: 1,
      pdf: { page: 0, rect: { x: 10, y: 10, width: 20, height: 20 }, rects: [] },
      text: "",
      note: privateText,
    },
  };
  assert.equal((await apply([privateOperation]))[0].status, "applied");
  assert.deepEqual(await delivered(token), before);
  const drawings = [
    {
      format: "bookorbit-ink-v1",
      strokes: [
        {
          id: "red-horizontal",
          color: "#ff0000",
          width: 8,
          points: [
            { x: 80, y: 200 + offset, pressure: 0.5 },
            { x: 180, y: 200 + offset, pressure: 0.8 },
          ],
        },
        {
          id: "blue-horizontal",
          color: "#0000ff",
          width: 8,
          points: [
            { x: 80, y: 230 + offset },
            { x: 180, y: 230 + offset },
          ],
        },
      ],
    },
    {
      format: "bookorbit-ink-v1",
      strokes: [
        {
          id: "green-horizontal",
          color: "#00ff00",
          width: 8,
          points: [
            { x: 250, y: 200 + offset },
            { x: 350, y: 200 + offset },
          ],
        },
      ],
    },
  ];
  const create = drawings.map((drawing, index) => ({
    operationId: randomUUID(),
    clientId: randomUUID(),
    bookId: 1,
    baseVersion: 0,
    action: "create",
    payload: {
      kind: "pdf_ink",
      bookFileId: 1,
      text: "",
      pdf: { page: 0, rect: { x: index ? 246 : 76, y: 196 + offset, width: 108, height: index ? 8 : 38 }, rects: [] },
      drawing,
      sourceRevision: initial.sourceRevision,
      pageFingerprint: initial.pageFingerprint,
    },
  }));
  const denied = await request("annotations/native/operations", reader.accessToken, { deviceId: "denied", operations: [create[0]] });
  assert.equal(denied.status, 403);
  assert.deepEqual(await delivered(token), before);
  const created = await apply(create);
  assert.equal(created.length, 2);
  for (const result of created) {
    assert.equal(result.status, "applied");
    assert.equal(result.publication.status, "published");
  }
  const publishedBytes = await delivered(token);
  assert.notDeepEqual(publishedBytes, before);
  assert.equal(createHash("sha256").update(publishedBytes).digest("hex"), created[0].publication.sourceRevision.slice(7));
  const document = await PDFDocument.load(publishedBytes);
  assert.equal(document.getPageCount(), 3);
  assert.equal(document.getPage(0).getWidth(), 600);
  assert.equal(document.getPage(0).getHeight(), 800);
  const sourceItems = items(document);
  for (const [index, result] of created.entries()) {
    const item = sourceItems.find(({ id }) => id === result.annotation.id);
    assert.ok(item, "each stroke group has a separately editable source item");
    assert.equal(item.annotation.get(PDFName.of("Subtype")).toString(), "/Ink");
    assert.equal(item.annotation.lookup(PDFName.of("NM"), PDFHexString).decodeText(), `bookorbit:${result.annotation.id}`);
    assert.deepEqual(JSON.parse(item.annotation.lookup(PDFName.of("BookOrbitDrawing"), PDFHexString).decodeText()), drawings[index]);
    assert.ok(item.annotation.has(PDFName.of("AP")), "ordinary viewers receive appearance data");
  }
  assert.ok(!publishedBytes.includes(Buffer.from(privateText)));
  assert.ok(
    !document.context
      .enumerateIndirectObjects()
      .some(([, object]) => object.toString().includes(privateText) || object.toString().includes(PDFHexString.fromText(privateText).toString())),
  );
  const renderedInitial = await rendered(publishedBytes, "published-grouped-ink");
  assert.deepEqual(pixel(renderedInitial, 120, 200 + offset), [255, 0, 0]);
  assert.deepEqual(pixel(renderedInitial, 120, 230 + offset), [0, 0, 255]);
  assert.deepEqual(pixel(renderedInitial, 300, 200 + offset), [0, 255, 0]);
  const retry = await apply(create);
  assert.equal(retry[0].annotation.id, created[0].annotation.id);
  assert.deepEqual(await delivered(token), publishedBytes);
  const matchingRequest = await request(`annotations/native/files/1/source?bookId=1&page=0&sourceRevision=${initial.sourceRevision}`, token);
  assert.equal(matchingRequest.status, 200);
  assert.equal((await matchingRequest.json()).matchedSourceRevision, initial.sourceRevision);
  const laterGroup = {
    ...create[1],
    operationId: randomUUID(),
    clientId: randomUUID(),
    payload: {
      ...create[1].payload,
      drawing: {
        format: "bookorbit-ink-v1",
        strokes: [
          {
            id: "later-black",
            color: "#000000",
            width: 8,
            points: [
              { x: 400, y: 300 + offset },
              { x: 500, y: 300 + offset },
            ],
          },
        ],
      },
    },
  };
  const merged = (await apply([laterGroup]))[0];
  assert.equal(merged.status, "applied");
  assert.equal(merged.publication.status, "published", "known prior source revision merges only ink on the unchanged page");
  const revision = await source(token);
  const deleted = (
    await apply([
      {
        operationId: randomUUID(),
        clientId: create[0].clientId,
        annotationId: created[0].annotation.id,
        bookId: 1,
        baseVersion: created[0].annotation.version,
        action: "delete",
        payload: { sourceRevision: revision.sourceRevision, pageFingerprint: revision.pageFingerprint },
      },
    ])
  )[0];
  assert.equal(deleted.status, "applied");
  assert.equal(deleted.publication.status, "published");
  const deletedBytes = await delivered(token);
  assert.ok(!items(await PDFDocument.load(deletedBytes)).some(({ id }) => id === created[0].annotation.id));
  const renderedDeleted = await rendered(deletedBytes, "deleted-first-group");
  assert.deepEqual(pixel(renderedDeleted, 120, 200 + offset), [255, 255, 255]);
  assert.deepEqual(pixel(renderedDeleted, 300, 200 + offset), [0, 255, 0]);
  const stale = (
    await apply([
      {
        operationId: randomUUID(),
        clientId: create[0].clientId,
        annotationId: created[0].annotation.id,
        bookId: 1,
        baseVersion: created[0].annotation.version,
        action: "update",
        payload: { drawing: drawings[0] },
      },
    ])
  )[0];
  assert.equal(stale.status, "recovery");
  assert.ok(stale.draftId);
  assert.deepEqual(await delivered(token), deletedBytes);
  const restoreSource = await source(token);
  const restored = (
    await apply([
      {
        operationId: randomUUID(),
        clientId: create[0].clientId,
        annotationId: created[0].annotation.id,
        bookId: 1,
        baseVersion: deleted.annotation.version,
        action: "restore",
        payload: { sourceRevision: restoreSource.sourceRevision, pageFingerprint: restoreSource.pageFingerprint },
      },
    ])
  )[0];
  assert.equal(restored.status, "applied");
  assert.equal(restored.publication.status, "published");
  const restoredBytes = await delivered(token);
  assert.ok(items(await PDFDocument.load(restoredBytes)).some(({ id }) => id === created[0].annotation.id));
  const renderedRestored = await rendered(restoredBytes, "restored-first-group");
  assert.deepEqual(pixel(renderedRestored, 120, 200 + offset), [255, 0, 0]);
  assert.deepEqual(pixel(renderedRestored, 300, 200 + offset), [0, 255, 0]);
});

test("IPAD-E02-A06-PDF: interruption before and after atomic source commit recovers a complete artifact through authenticated operation retry", async (t) => {
  const owner = await login("ipad-owner");
  const token = owner.accessToken;
  const before = await delivered(token);
  const apply = await isolatedOperations(t, token, before);
  const baselineImage = await rendered(before, "baseline-interruption");
  const offset = blankOffset(baselineImage, [
    [80, 180, 400],
    [80, 180, 450],
  ]);
  for (const [index, phase] of ["prepared", "committed"].entries()) {
    const original = await delivered(token);
    const current = await source(token);
    const operation = {
      operationId: randomUUID(),
      clientId: randomUUID(),
      bookId: 1,
      baseVersion: 0,
      action: "create",
      payload: {
        kind: "pdf_ink",
        bookFileId: 1,
        text: "",
        sourceRevision: current.sourceRevision,
        pageFingerprint: current.pageFingerprint,
        pdf: { page: 0, rect: { x: 80, y: 400 + index * 50 + offset, width: 100, height: 8 }, rects: [] },
        drawing: {
          format: "bookorbit-ink-v1",
          strokes: [
            {
              id: `fault-${phase}`,
              color: "#ff0000",
              width: 8,
              points: [
                { x: 80, y: 400 + index * 50 + offset },
                { x: 180, y: 400 + index * 50 + offset },
              ],
            },
          ],
        },
      },
    };
    assert.equal((await request(`__faults/source-pdf/arm/${phase}`, token, null, "POST")).status, 204);
    const failed = (await apply([operation]))[0];
    assert.equal(failed.status, "applied");
    assert.equal(failed.publication.status, "failed");
    const interrupted = await delivered(token);
    assert.equal((await PDFDocument.load(interrupted)).getPageCount(), 3, "delivery is a complete PDF at either interruption boundary");
    if (phase === "prepared") assert.deepEqual(interrupted, original);
    else assert.notDeepEqual(interrupted, original);
    const state = await request("__faults/source-pdf/state", token);
    assert.equal((await state.json()).observed, phase);
    const retried = (await apply([operation]))[0];
    assert.equal(retried.status, "applied");
    assert.notEqual(retried.publication.status, "failed");
    assert.equal(retried.annotation.id, failed.annotation.id);
    const recovered = await delivered(token);
    const grouped = items(await PDFDocument.load(recovered)).filter(({ id }) => id === failed.annotation.id);
    assert.equal(grouped.length, 1);
    const image = await rendered(recovered, `recovered-${phase}`);
    assert.deepEqual(pixel(image, 120, 400 + index * 50 + offset), [255, 0, 0]);
    assert.equal((await source(token)).sourceRevision, `sha256:${createHash("sha256").update(recovered).digest("hex")}`);
  }
});
