import { randomUUID, createHash } from "node:crypto";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { writeFile } from "node:fs/promises";
import { createRequire } from "node:module";
import { test, expect } from "@playwright/test";
import { captureAnnotationVisual } from "./annotation-visual.mjs";

const execute = promisify(execFile);
const require = createRequire(new URL("../../server/package.json", import.meta.url));
const { PDFDocument, PDFName, PDFNumber, PDFHexString } = require("pdf-lib");
const sharp = require("sharp");
const cfi = "epubcfi(/6/2[c1ref]!/4/2[p1],/1:0,/1:5)";
const drawing = {
  format: "bookorbit-ink-v1",
  strokes: [
    {
      id: "RAW-INK-SEARCH-MUST-NOT-MATCH",
      color: "#ff0000",
      width: 8,
      points: [
        { x: 80, y: 200 },
        { x: 180, y: 200 },
      ],
    },
  ],
};

test.beforeEach(async ({ page }) => {
  page.setDefaultTimeout(15_000);
});

async function json(response) {
  expect(response.ok(), `${response.status()} ${await response.text()}`).toBe(true);
  return response.json();
}

async function nativeSession(request, username = "ipad-owner") {
  const credentials = await json(
    await request.post("/api/v1/auth/login", {
      data: { username, password: "IpadFixture123", clientKind: "native", deviceLabel: "E02 browser input fixture" },
    }),
  );
  return { credentials, headers: { Authorization: `Bearer ${credentials.accessToken}` } };
}

async function signIn(page, username = "ipad-owner") {
  await page.goto("/login");
  await page.locator("#username").fill(username);
  await page.locator("#password").fill("IpadFixture123");
  const response = page.waitForResponse((entry) => entry.url().endsWith("/auth/login") && entry.request().method() === "POST");
  await page.getByRole("button", { name: "Sign in", exact: true }).click();
  expect((await response).status()).toBe(200);
  await expect(page).not.toHaveURL(/\/login/);
}

async function operation(request, session, item) {
  const result = await json(
    await request.post("/api/v1/annotations/native/operations", {
      headers: session.headers,
      data: { deviceId: "browser-controlled-native-input", operations: [item] },
    }),
  );
  expect(result.results).toHaveLength(1);
  return result.results[0];
}

async function create(request, session, bookId, payload) {
  const result = await operation(request, session, {
    operationId: randomUUID(),
    clientId: randomUUID(),
    bookId,
    baseVersion: 0,
    action: "create",
    payload,
  });
  expect(result.status).toBe("applied");
  return result;
}

async function source(request, session) {
  return json(await request.get("/api/v1/annotations/native/files/1/source?bookId=1&page=0", { headers: session.headers }));
}

async function seedInk(request, session, x = 80, color = "#ff0000") {
  const current = await source(request, session);
  return create(request, session, 1, {
    kind: "pdf_ink",
    bookFileId: 1,
    text: "",
    sourceRevision: current.sourceRevision,
    pageFingerprint: current.pageFingerprint,
    pdf: { page: 0, rect: { x: x - 4, y: 596, width: 108, height: 8 }, rects: [] },
    drawing: {
      ...drawing,
      strokes: [
        {
          ...drawing.strokes[0],
          id: "browser-source-ink-fixture",
          color,
          points: [
            { x, y: 600 },
            { x: x + 100, y: 600 },
          ],
        },
      ],
    },
  });
}

async function resetBrowserInk(request, session) {
  const sourceItems = await json(
    await request.get("/api/v1/annotations/native/source-ink?bookId=1&bookFileId=1&cursor=0&limit=100&page=0", { headers: session.headers }),
  );
  expect(sourceItems.hasMore).toBe(false);
  for (const item of sourceItems.items.filter(
    (entry) => !entry.deletedAt && entry.drawing?.strokes.some((stroke) => stroke.id === "browser-source-ink-fixture"),
  )) {
    const deleted = await operation(request, session, {
      operationId: randomUUID(),
      clientId: item.clientId,
      annotationId: item.id,
      bookId: 1,
      baseVersion: item.version,
      action: "delete",
    });
    expect(deleted.status).toBe("applied");
  }
}

async function resetBrowserNote(request, session, bookId, marker) {
  const prior = await json(
    await request.get(`/api/v1/annotations/native/hub?bookId=${bookId}&search=${encodeURIComponent(marker)}&limit=100`, { headers: session.headers }),
  );
  expect(prior.nextCursor).toBeNull();
  for (const item of prior.items.filter((entry) => entry.note === marker || entry.note?.startsWith(`${marker}:`))) {
    expect(
      (
        await operation(request, session, {
          operationId: randomUUID(),
          clientId: item.clientId,
          annotationId: item.id,
          bookId,
          baseVersion: item.version,
          action: "delete",
        })
      ).status,
    ).toBe("applied");
  }
}

async function delivered(request, session, info, state) {
  const response = await request.get("/api/v1/books/files/1/serve", { headers: session.headers });
  expect(response.status()).toBe(200);
  const bytes = await response.body();
  const path = info.outputPath(`${state}.pdf`);
  await writeFile(path, bytes);
  const document = await PDFDocument.load(bytes);
  expect(document.getPageCount()).toBe(3);
  expect(document.getPage(0).getSize()).toEqual({ width: 600, height: 800 });
  const items = document.getPages().flatMap((page) =>
    (page.node.Annots()?.asArray() ?? []).flatMap((reference) => {
      const entry = document.context.lookup(reference);
      const id = entry.lookupMaybe(PDFName.of("BookOrbitAnnotationId"), PDFNumber)?.asNumber();
      return id == null ? [] : [{ id, drawing: JSON.parse(entry.lookup(PDFName.of("BookOrbitDrawing"), PDFHexString).decodeText()) }];
    }),
  );
  await execute("/opt/homebrew/bin/pdftoppm", [
    "-f",
    "1",
    "-singlefile",
    "-scale-to-x",
    "600",
    "-scale-to-y",
    "800",
    "-png",
    path,
    info.outputPath(state),
  ]);
  const text = await execute("/opt/homebrew/bin/pdftotext", [path, "-"]);
  expect(text.stdout).toContain("Orbit fixture: passage 1");
  expect(text.stdout).toContain("Orbit fixture: passage 3");
  const pixels = await sharp(info.outputPath(`${state}.png`))
    .removeAlpha()
    .raw()
    .toBuffer({ resolveWithObject: true });
  const pixel = (x, y) => {
    const offset = (y * pixels.info.width + x) * pixels.info.channels;
    return [...pixels.data.subarray(offset, offset + 3)];
  };
  return { bytes, items, pixel, revision: `sha256:${createHash("sha256").update(bytes).digest("hex")}` };
}

async function openPdf(page, id) {
  await page.goto("/book/1");
  await page.getByRole("button", { name: "Read", exact: true }).click();
  await expect(page.getByRole("spinbutton", { name: "Current page", exact: true })).toHaveValue("1");
  await expect(page.getByTestId(`source-ink-${id}`)).toBeVisible();
  await page.getByTestId(`source-ink-${id}`).scrollIntoViewIfNeeded();
  await expect(page.getByTestId(`source-ink-${id}`)).toBeInViewport();
}

function mutation(page, action, id) {
  return page.waitForResponse(
    (response) =>
      /\/annotations\/native\/(?:source-ink\/1\/1\/)?operations$/.test(response.url()) &&
      response.request().method() === "POST" &&
      response
        .request()
        .postDataJSON()
        ?.operations.some((entry) => entry.action === action && entry.annotationId === id),
  );
}

async function visibleEpubPassage(page) {
  await expect.poll(() => page.frames().some((frame) => frame.url().startsWith("blob:"))).toBe(true);
  const frame = page.frames().find((entry) => entry.url().startsWith("blob:"));
  const paragraph = frame.getByText("Alpha 😀 café omega.", { exact: true });
  await expect(paragraph).toBeVisible();
  await expect(paragraph).toBeInViewport();
}

test("IPAD-E02-A01-web: owned retained passage handwriting displays, reflows, and searches converted text only", async ({ page, request }, info) => {
  const username = process.env.IPAD_E02_EXPECT_NATIVE === "1" ? "ipad-owner" : "ipad-reader";
  const session = await nativeSession(request, username);
  const marker = `Browser English Scribble completion fixture ${username}`;
  await resetBrowserNote(request, session, 2, "Browser English Scribble completion fixture");
  await resetBrowserNote(request, session, 2, marker);
  const created = await create(request, session, 2, { kind: "handwriting", bookFileId: 2, cfi, text: "Alpha", note: marker, drawing });
  const nativeNotes = await json(await request.get("/api/v1/books/2/annotations?page=1&pageSize=100", { headers: session.headers }));
  await writeFile(info.outputPath("native-passage-annotations.json"), `${JSON.stringify(nativeNotes, null, 2)}\n`);
  if (process.env.IPAD_E02_EXPECT_NATIVE === "1") {
    expect(nativeNotes.items.some((item) => item.note === "Converted English passage fixture")).toBe(true);
    expect(nativeNotes.items.some((item) => item.kind === "handwriting" && item.drawing?.strokes.length >= 2)).toBe(true);
  }
  expect(
    (await request.post("/api/v1/books/files/2/progress", { headers: session.headers, data: { source: "text", percentage: 0, cfi } })).status(),
  ).toBe(201);
  await signIn(page, username);
  await page.goto("/read/2/2");
  await visibleEpubPassage(page);
  await expect(page.getByRole("button", { name: "Table of contents", exact: true })).toBeAttached();
  await page.keyboard.press("t");
  await page.getByRole("button", { name: "Highlights", exact: true }).click();
  const search = page.getByPlaceholder("Search highlights...", { exact: true });
  if (process.env.IPAD_E02_EXPECT_NATIVE === "1") {
    await search.fill("Converted English passage fixture");
    await expect(page.getByText("Converted English passage fixture", { exact: true })).toBeVisible();
    await captureAnnotationVisual(page, info, "A01-actual-native-converted-note-in-web");
    const nativeInk = nativeNotes.items.find((item) => item.kind === "handwriting" && item.drawing?.strokes.length >= 2);
    await search.fill(nativeInk.text);
    const retainedNative = page.getByTestId("passage-handwriting").filter({ has: page.locator("polyline:nth-of-type(2)") });
    await expect(retainedNative).toBeVisible();
    await expect(retainedNative.locator("polyline")).toHaveCount(2);
    for (const [index, stroke] of nativeInk.drawing.strokes.entries()) {
      await expect(retainedNative.locator("polyline").nth(index)).toHaveAttribute(
        "points",
        stroke.points.map((point) => `${point.x},${point.y}`).join(" "),
      );
    }
    await captureAnnotationVisual(page, info, "A01-actual-native-edited-handwriting-in-web");
  }
  await search.fill(marker);
  await expect(page.getByText(marker, { exact: true })).toBeVisible();
  const ink = page.getByTestId("passage-handwriting");
  await expect(ink).toHaveCount(1);
  await expect(ink.locator("polyline")).toHaveAttribute("points", "80,200 180,200");
  await captureAnnotationVisual(page, info, "A01-passage-handwriting-initial-window");
  const viewport = page.viewportSize();
  await page.setViewportSize({ width: viewport.height, height: viewport.width });
  await expect(page.getByText(marker, { exact: true })).toBeVisible();
  await expect(ink.locator("polyline")).toHaveAttribute("points", "80,200 180,200");
  await captureAnnotationVisual(page, info, "A01-passage-handwriting-rotated-window");
  await page.getByRole("button", { name: "Close sidebar", exact: true }).click();
  await visibleEpubPassage(page);
  await captureAnnotationVisual(page, info, "A01-visible-passage-after-rotation");
  await page.keyboard.press("t");
  await page.getByRole("button", { name: "Highlights", exact: true }).click();
  await search.fill("RAW-INK-SEARCH-MUST-NOT-MATCH");
  await expect(page.getByText("No highlights match your filters", { exact: true })).toBeVisible();
  await expect(ink).toHaveCount(0);
  const hub = await json(
    await request.get("/api/v1/annotations/native/hub?search=RAW-INK-SEARCH-MUST-NOT-MATCH&limit=100", { headers: session.headers }),
  );
  expect(hub.items.some((item) => item.id === created.annotation.id)).toBe(false);
  const other = await nativeSession(request, username === "ipad-owner" ? "ipad-reader" : "ipad-owner");
  const foreign = await json(
    await request.get(`/api/v1/annotations/native/hub?search=${encodeURIComponent(marker)}&limit=100`, { headers: other.headers }),
  );
  expect(foreign.items).toEqual([]);
  await captureAnnotationVisual(page, info, "A01-text-only-search-empty");
});

test("IPAD-E02-A03-web/IPAD-E02-A02: right-click delete, precommit Undo, and versioned inverse converge with source PDF and newer ink", async ({
  page,
  request,
}, info) => {
  const session = await nativeSession(request);
  await resetBrowserInk(request, session);
  const original = await seedInk(request, session);
  expect(original.publication.status).toBe("published");
  const privateMarker = "PRIVATE-WEB-PASSAGE-NOT-IN-PDF";
  await resetBrowserNote(request, session, 1, privateMarker);
  await create(request, session, 1, {
    kind: "text_note",
    bookFileId: 1,
    text: "",
    note: privateMarker,
    pdf: { page: 0, rect: { x: 10, y: 10, width: 20, height: 20 }, rects: [] },
  });
  const before = await delivered(request, session, info, "A03-before-delete");
  expect(before.revision).toBe(original.publication.sourceRevision);
  expect(before.items.some((item) => item.id === original.annotation.id)).toBe(true);
  expect(before.pixel(120, 600)).toEqual([255, 0, 0]);
  expect(before.bytes.includes(Buffer.from(privateMarker))).toBe(false);
  const sourceDocument = await PDFDocument.load(before.bytes);
  expect(sourceDocument.context.enumerateIndirectObjects().some(([, value]) => value.toString().includes(privateMarker))).toBe(false);
  await signIn(page);
  await openPdf(page, original.annotation.id);
  const ink = page.getByTestId(`source-ink-${original.annotation.id}`);
  await ink.click({ button: "right" });
  await expect(page.getByRole("menuitem", { name: "Delete", exact: true })).toBeVisible();
  await captureAnnotationVisual(page, info, "A03-source-ink-context-menu");
  await page.clock.install();
  await page.clock.pauseAt(new Date(Date.now() + 100));
  const requests = [];
  page.on("request", (entry) => {
    if (/\/annotations\/native\/(?:source-ink\/1\/1\/)?operations$/.test(entry.url())) requests.push(entry.postDataJSON());
  });
  await page.getByRole("menuitem", { name: "Delete", exact: true }).click();
  await expect(ink).toHaveCount(0);
  await page.getByRole("button", { name: "Undo", exact: true }).click();
  await page.clock.runFor(500);
  await expect(ink).toBeVisible();
  expect(requests).toEqual([]);
  expect((await delivered(request, session, info, "A03-precommit-undo")).bytes).toEqual(before.bytes);
  await page.clock.resume();
  await ink.click({ button: "right" });
  const deletion = mutation(page, "delete", original.annotation.id);
  await page.getByRole("menuitem", { name: "Delete", exact: true }).click();
  const deletedResponse = await deletion;
  const deleted = (await json(deletedResponse)).results[0];
  expect(deleted.status).toBe("applied");
  expect(deleted.annotation.version).toBe(original.annotation.version + 1);
  expect(deleted.publication.status).toBe("published");
  await expect(ink).toHaveCount(0);
  const removed = await delivered(request, session, info, "A03-committed-delete");
  expect(removed.items.some((item) => item.id === original.annotation.id)).toBe(false);
  expect(removed.pixel(120, 600)).toEqual([255, 255, 255]);
  const newer = await seedInk(request, session, 250, "#00ff00");
  await expect(page.getByTestId(`source-ink-${newer.annotation.id}`)).toBeVisible();
  await captureAnnotationVisual(page, info, "A03-deleted-with-newer-content");
  const inverse = mutation(page, "restore", original.annotation.id);
  await page.getByRole("button", { name: "Undo", exact: true }).click();
  const inverseResponse = await inverse;
  const inversePayload = inverseResponse.request().postDataJSON().operations[0];
  expect(inversePayload.baseVersion).toBe(deleted.annotation.version);
  expect(inversePayload.operationId).not.toBe(deletedResponse.request().postDataJSON().operations[0].operationId);
  const restored = (await json(inverseResponse)).results[0];
  expect(restored.status).toBe("applied");
  expect(restored.annotation.version).toBe(deleted.annotation.version + 1);
  await expect(ink).toBeVisible();
  await expect(page.getByTestId(`source-ink-${newer.annotation.id}`)).toBeVisible();
  await expect(page.getByRole("spinbutton", { name: "Current page", exact: true })).toHaveValue("1");
  await expect(ink).toHaveAttribute("x", "76");
  await expect(ink).toHaveAttribute("y", "596");
  const final = await delivered(request, session, info, "A03-versioned-inverse");
  expect(final.items.find((item) => item.id === original.annotation.id).drawing).toEqual(original.annotation.drawing);
  expect(final.items.find((item) => item.id === newer.annotation.id).drawing).toEqual(newer.annotation.drawing);
  expect(final.pixel(120, 600)).toEqual([255, 0, 0]);
  expect(final.pixel(300, 600)).toEqual([0, 255, 0]);
  expect((await source(request, session)).sourceRevision).toBe(final.revision);
  const native = await json(await request.get("/api/v1/annotations/native/delta?bookId=1&cursor=0&limit=100", { headers: session.headers }));
  expect(native.items.find((item) => item.id === original.annotation.id).version).toBe(restored.annotation.version);
  await writeFile(info.outputPath("A03-public-native-delta.json"), `${JSON.stringify(native, null, 2)}\n`);
  await captureAnnotationVisual(page, info, "A03-undo-source-convergence");
});

test("IPAD-E02-A05-web: committed browser deletion retains stale native edits as recovery drafts without resurrection", async ({
  page,
  request,
}, info) => {
  const session = await nativeSession(request);
  if (process.env.IPAD_E02_CONCURRENT_NATIVE === "1") {
    const checkpoint = "http://localhost:16485/__faults/annotations/checkpoint/";
    await expect.poll(async () => (await json(await request.get(`${checkpoint}native-offline-ready`))).reached, { timeout: 120_000 }).toBe(true);
    const available = await json(
      await request.get("/api/v1/annotations/native/source-ink?bookId=1&bookFileId=1&cursor=0&limit=100&page=0", { headers: session.headers }),
    );
    const original = available.items.filter((item) => item.kind === "pdf_ink" && !item.deletedAt).sort((left, right) => right.id - left.id)[0];
    expect(original).toBeDefined();
    await signIn(page);
    await openPdf(page, original.id);
    await page.getByTestId(`source-ink-${original.id}`).click({ button: "right" });
    const deletion = mutation(page, "delete", original.id);
    await page.getByRole("menuitem", { name: "Delete", exact: true }).click();
    expect((await json(await deletion)).results[0].status).toBe("applied");
    const removed = await delivered(request, session, info, "A05-concurrent-browser-delete");
    expect(removed.items.some((item) => item.id === original.id)).toBe(false);
    expect((await request.post(`${checkpoint}browser-delete-done`)).status()).toBe(204);
    await expect.poll(async () => (await json(await request.get(`${checkpoint}native-reconciled`))).reached, { timeout: 120_000 }).toBe(true);
    const delta = await json(await request.get("/api/v1/annotations/native/delta?bookId=1&cursor=0&limit=100", { headers: session.headers }));
    const tombstone = delta.items.find((item) => item.id === original.id);
    expect(tombstone.deletedAt).not.toBeNull();
    expect(tombstone.version).toBeGreaterThan(original.version);
    await writeFile(
      info.outputPath("A05-concurrent-native-recovery.json"),
      `${JSON.stringify({ original, tombstone, nativeRecoveryEvidence: "native-reconciled checkpoint follows native visible recovery assertion" }, null, 2)}\n`,
    );
    await expect(page.getByTestId(`source-ink-${original.id}`)).toHaveCount(0);
    expect((await delivered(request, session, info, "A05-concurrent-native-reconciled")).bytes).toEqual(removed.bytes);
    await captureAnnotationVisual(page, info, "A05-concurrent-native-recovery-no-resurrection");
    return;
  }
  await resetBrowserInk(request, session);
  const original = await seedInk(request, session, 400, "#0000ff");
  await signIn(page);
  await openPdf(page, original.annotation.id);
  await page.getByTestId(`source-ink-${original.annotation.id}`).click({ button: "right" });
  const deletion = mutation(page, "delete", original.annotation.id);
  await page.getByRole("menuitem", { name: "Delete", exact: true }).click();
  expect((await json(await deletion)).results[0].status).toBe("applied");
  const removed = await delivered(request, session, info, "A05-authoritative-delete");
  const staleDrawing = {
    format: "bookorbit-ink-v1",
    strokes: [
      {
        id: "browser-source-ink-fixture",
        color: "#0000ff",
        width: 8,
        points: [
          { x: 405, y: 600 },
          { x: 505, y: 600 },
        ],
      },
    ],
  };
  const pending = {
    operationId: randomUUID(),
    clientId: original.annotation.clientId,
    annotationId: original.annotation.id,
    bookId: 1,
    baseVersion: original.annotation.version,
    action: "update",
    payload: { drawing: staleDrawing },
  };
  const stale = await operation(request, session, pending);
  expect(stale.status).toBe("recovery");
  expect(stale.draftId).toBeGreaterThan(0);
  expect(await operation(request, session, pending)).toEqual(stale);
  const drafts = await json(await request.get("/api/v1/annotations/native/hub/drafts?bookId=1&limit=100", { headers: session.headers }));
  expect(drafts.items.find((item) => item.id === stale.draftId).payload.payload.drawing).toEqual(staleDrawing);
  await writeFile(info.outputPath("A05-recoverable-native-drafts.json"), `${JSON.stringify(drafts, null, 2)}\n`);
  await expect(page.getByTestId(`source-ink-${original.annotation.id}`)).toHaveCount(0);
  await page.reload();
  await expect(page.getByRole("spinbutton", { name: "Current page", exact: true })).toHaveValue("1");
  await expect(page.getByTestId(`source-ink-${original.annotation.id}`)).toHaveCount(0);
  const final = await delivered(request, session, info, "A05-recovery-does-not-recreate");
  expect(final.bytes).toEqual(removed.bytes);
  expect(final.items.some((item) => item.id === original.annotation.id)).toBe(false);
  await captureAnnotationVisual(page, info, "A05-authoritative-delete-after-reconnect");
});

test("IPAD-E02-A03-web-permission: read-only source access hides deletion and rejects unauthorized writes", async ({ page, request }, info) => {
  const owner = await nativeSession(request);
  await resetBrowserInk(request, owner);
  const seeded = await seedInk(request, owner, 400, "#0000ff");
  await signIn(page, "ipad-reader");
  await openPdf(page, seeded.annotation.id);
  await page.getByTestId(`source-ink-${seeded.annotation.id}`).click({ button: "right" });
  await expect(page.getByTestId(`source-ink-${seeded.annotation.id}`)).toHaveAttribute("aria-pressed", "true");
  const reader = await nativeSession(request, "ipad-reader");
  expect((await source(request, reader)).canEditPdfInk).toBe(false);
  const denied = await request.post("/api/v1/annotations/native/source-ink/1/1/operations", {
    headers: reader.headers,
    data: {
      deviceId: "denied-web-input",
      operations: [
        {
          operationId: randomUUID(),
          clientId: seeded.annotation.clientId,
          annotationId: seeded.annotation.id,
          bookId: 1,
          baseVersion: seeded.annotation.version,
          action: "delete",
        },
      ],
    },
  });
  expect(denied.status()).toBe(403);
  await expect(page.getByRole("spinbutton", { name: "Current page", exact: true })).toHaveValue("1");
  await expect(page.getByRole("button", { name: "Delete", exact: true })).toHaveCount(0);
  await expect(page.getByRole("menuitem", { name: "Delete", exact: true })).toHaveCount(0);
  await captureAnnotationVisual(page, info, "A03-read-only-source-permission");
});

test("IPAD-E02-A05-web-private: an open retained-note popover preserves typed input and the newer canonical version on conflict", async ({
  page,
  request,
}, info) => {
  const session = await nativeSession(request, "ipad-reader");
  const marker = "Browser private passage conflict fixture";
  const typed = "Unsaved browser note must survive conflict";
  await resetBrowserNote(request, session, 2, marker);
  await resetBrowserNote(request, session, 2, typed);
  const anchor = "epubcfi(/6/2[c1ref]!/4/4[p2],/1:0,/1:5)";
  const original = await create(request, session, 2, { kind: "handwriting", bookFileId: 2, cfi: anchor, text: "First", note: marker, drawing });
  expect(
    (
      await request.post("/api/v1/books/files/2/progress", { headers: session.headers, data: { source: "text", percentage: 0, cfi: anchor } })
    ).status(),
  ).toBe(201);
  await signIn(page, "ipad-reader");
  const loaded = page.waitForResponse((response) => response.url().includes("/books/2/annotations?") && response.request().method() === "GET");
  await page.goto("/read/2/2");
  expect((await loaded).ok()).toBe(true);
  await visibleEpubPassage(page);
  const chapter = page.frames().find((frame) => frame.url().startsWith("blob:"));
  await chapter.evaluate(() => document.fonts.ready.then(() => undefined));
  await chapter.getByText("First chapter ends here.", { exact: true }).click({ position: { x: 15, y: 10 } });
  const input = page.getByPlaceholder("Write your note…", { exact: true });
  await expect(input).toHaveValue(marker);
  await expect(page.getByTestId("passage-handwriting")).toBeVisible();
  const newerNote = `${marker}: newer native note remains canonical`;
  await input.fill(typed);
  const reflected = page.waitForResponse(async (response) => {
    if (!response.url().includes("/annotations/native/delta?") || !response.url().includes("bookId=2")) return false;
    const delta = await response.json();
    return delta.items?.some((item) => item.id === original.annotation.id && item.version === original.annotation.version + 1);
  });
  const newer = await operation(request, session, {
    operationId: randomUUID(),
    clientId: original.annotation.clientId,
    annotationId: original.annotation.id,
    bookId: 2,
    baseVersion: original.annotation.version,
    action: "update",
    payload: { note: newerNote },
  });
  expect(newer.status).toBe("applied");
  await (await reflected).finished();
  await chapter.evaluate(() => new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve))));
  await expect(input).toHaveValue(typed);
  const response = mutation(page, "update", original.annotation.id);
  await page.getByRole("button", { name: "Save", exact: true }).click();
  const saved = await response;
  expect(saved.request().postDataJSON().operations[0].baseVersion).toBe(original.annotation.version);
  const conflict = (await json(saved)).results[0];
  expect(conflict.status).toBe("conflict");
  await expect(input).toHaveValue(typed);
  await expect(input).toBeEnabled();
  const canonical = await json(await request.get("/api/v1/books/2/annotations?page=1&pageSize=100", { headers: session.headers }));
  expect(canonical.items.find((item) => item.id === original.annotation.id).note).toBe(newerNote);
  const drafts = await json(await request.get("/api/v1/annotations/native/hub/drafts?bookId=2&limit=100", { headers: session.headers }));
  expect(drafts.items.find((item) => item.id === conflict.draftId).payload.payload.note).toBe(typed);
  await writeFile(info.outputPath("A05-private-popover-conflict.json"), `${JSON.stringify({ conflict, canonical, drafts }, null, 2)}\n`);
  const feedback = page.locator("[data-sonner-toast]").filter({ hasText: "Failed" });
  await expect(feedback).toBeVisible();
  await expect
    .poll(async () => {
      const bounds = await feedback.boundingBox();
      return bounds && bounds.y >= 0 && bounds.y + bounds.height <= page.viewportSize().height;
    })
    .toBe(true);
  await captureAnnotationVisual(page, info, "A05-private-popover-conflict-retains-input");
});

test("IPAD-E02-A06-web: replacement PDF hides old source selection and preserves retained canonical ink", async ({ page, request }, info) => {
  const session = await nativeSession(request);
  const changeSource = async (mode) => {
    expect((await request.post(`/api/v1/__faults/source-pdf/source/1/${mode}`, { headers: session.headers })).status()).toBe(204);
  };
  await changeSource("restore");
  const originalSource = await source(request, session);
  const originalArtifact = await delivered(request, session, info, "A06-original-source");
  const sourceItems = await json(
    await request.get("/api/v1/annotations/native/source-ink?bookId=1&bookFileId=1&cursor=0&limit=100&page=0", { headers: session.headers }),
  );
  expect(sourceItems.hasMore).toBe(false);
  const initial = sourceItems.items.find(
    (item) =>
      !item.deletedAt &&
      item.pageFingerprint === originalSource.pageFingerprint &&
      originalArtifact.items.some((embedded) => embedded.id === item.id),
  );
  expect(initial, "A06 requires a live canonical group embedded in the saved source fixture").toBeTruthy();
  await signIn(page);
  await openPdf(page, initial.id);
  const requests = [];
  page.on("request", (entry) => {
    if (entry.method() === "POST" && /\/annotations\/native\/(?:source-ink\/1\/1\/)?operations$/.test(entry.url())) requests.push(entry);
  });
  try {
    await changeSource("replace");
    const replaced = await source(request, session);
    expect(replaced.pageFingerprint).not.toBe(originalSource.pageFingerprint);
    expect(replaced).toMatchObject({ width: 420, height: 600 });
    const response = await request.get("/api/v1/books/files/1/serve", { headers: session.headers });
    expect(response.status()).toBe(200);
    const bytes = await response.body();
    expect(`sha256:${createHash("sha256").update(bytes).digest("hex")}`).toBe(replaced.sourceRevision);
    const path = info.outputPath("A06-replacement.pdf");
    await writeFile(path, bytes);
    const document = await PDFDocument.load(bytes);
    expect(document.getPageCount()).toBe(1);
    expect(document.getPage(0).getSize()).toEqual({ width: 420, height: 600 });
    expect((await execute("/opt/homebrew/bin/pdftotext", [path, "-"])).stdout).toContain("Replacement source fixture");
    await execute("/opt/homebrew/bin/pdftoppm", ["-f", "1", "-singlefile", "-png", "-r", "72", path, info.outputPath("A06-replacement")]);
    await expect(page.getByRole("spinbutton", { name: "Current page", exact: true })).toHaveAttribute("max", "1");
    await expect(page.locator('[data-testid^="source-ink-"]')).toHaveCount(0);
    await expect(page.getByRole("button", { name: "Delete", exact: true })).toHaveCount(0);
    expect(requests).toHaveLength(0);
    const delta = await json(await request.get("/api/v1/annotations/native/delta?bookId=1&cursor=0&limit=100", { headers: session.headers }));
    expect(delta.items.find((item) => item.id === initial.id)).toMatchObject({
      version: initial.version,
      deletedAt: null,
      pageFingerprint: originalSource.pageFingerprint,
    });
    await writeFile(info.outputPath("A06-source-replacement.json"), `${JSON.stringify({ originalSource, replaced, delta }, null, 2)}\n`);
    await captureAnnotationVisual(page, info, "A06-replacement-hides-old-source-selection");
  } finally {
    await changeSource("restore");
    const restored = await delivered(request, session, info, "A06-restored-source");
    expect(restored.bytes.equals(originalArtifact.bytes)).toBe(true);
    expect(restored.items.some((item) => item.id === initial.id)).toBe(true);
  }
  await expect(page.getByRole("spinbutton", { name: "Current page", exact: true })).toHaveAttribute("max", "3");
  await expect(page.getByRole("spinbutton", { name: "Current page", exact: true })).toHaveValue("1");
  await expect(page.getByTestId(`source-ink-${initial.id}`)).toBeVisible();
  expect(requests).toHaveLength(0);
  await captureAnnotationVisual(page, info, "A06-restored-source-geometry");
});
