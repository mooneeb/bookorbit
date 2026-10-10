import { createHash, randomUUID } from "node:crypto";
import { createRequire } from "node:module";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { writeFile } from "node:fs/promises";
import { test as base, expect, request as publicRequest } from "@playwright/test";
import { captureAnnotationVisual } from "./annotation-visual.mjs";

const require = createRequire(new URL("../../server/package.json", import.meta.url));
const { PDFDocument, PDFName, PDFNumber } = require("pdf-lib");
const sharp = require("sharp");
const execute = promisify(execFile);
const api = process.env.IPAD_SOURCE_INK_API_URL ?? "http://localhost:16482/api/v1";
const route = (window = 1) => `/annotations/native/source-ink/window?bookId=1&bookFileId=1&page=0&window=${window}&limit=100`;
const hash = (bytes) => createHash("sha256").update(bytes).digest("hex");

async function json(response) {
  expect(response.ok(), `${response.status()} ${await response.text()}`).toBe(true);
  return response.json();
}

async function connect() {
  const request = await publicRequest.newContext({ baseURL: api, timeout: 30_000 });
  const login = await json(
    await request.post(`${api}/auth/login`, {
      data: {
        username: "ipad-owner",
        password: "IpadFixture123",
        clientKind: "native",
        deviceLabel: "Source ink window fixture",
      },
    }),
  );
  return { request, headers: { Authorization: `Bearer ${login.accessToken}` } };
}

async function get(context, path) {
  return json(await context.request.get(`${api}${path}`, { headers: context.headers }));
}

async function mutate(context, operations, timeout = 30_000) {
  const result = await json(
    await context.request.post(`${api}/annotations/native/source-ink/1/1/operations`, {
      headers: context.headers,
      data: { deviceId: "source-window-web", operations },
      timeout,
    }),
  );
  expect(result.results).toHaveLength(operations.length);
  for (const entry of result.results) {
    expect(entry.status).toBe("applied");
    expect(entry.publication.status).toBe("published");
  }
  return result.results.map((entry) => entry.annotation);
}

async function bytes(context) {
  const response = await context.request.get(`${api}/books/files/1/serve`, { headers: context.headers });
  expect(response.status()).toBe(200);
  return response.body();
}

function payload(index, snapshot) {
  const oldest = index === 0;
  const remote = index === 1101;
  const x = oldest ? 80 : remote ? 250 : 20 + (index % 40) * 12;
  const y = oldest || remote ? 500 : 650 + Math.floor(index / 40) * 3;
  const length = oldest || remote ? 100 : 2;
  return {
    kind: "pdf_ink",
    bookFileId: 1,
    text: "",
    sourceRevision: snapshot.sourceRevision,
    pageFingerprint: snapshot.pageFingerprint,
    pdf: { page: 0, rect: { x: x - 4, y: y - 4, width: length + 8, height: 8 }, rects: [] },
    drawing: {
      format: "bookorbit-ink-v1",
      strokes: [
        {
          id: `source-window-${index}`,
          color: oldest ? "#ff0000" : remote ? "#00ff00" : "#888888",
          width: 4,
          points: [
            { x, y },
            { x: x + length, y },
          ],
        },
      ],
    },
  };
}

async function cleanup(context, uuids, initial, deadline) {
  for (let batch = 0; batch < 20; batch++) {
    if (Date.now() >= deadline) throw new Error("Source fixture cleanup exceeded its finite budget");
    const window = await get(context, route());
    const own = window.items.filter((entry) => uuids.has(entry.clientId));
    if (!own.length) {
      expect(window.total).toBe(initial.total);
      expect(window.items.map((entry) => [entry.id, entry.version])).toEqual(initial.items.map((entry) => [entry.id, entry.version]));
      return;
    }
    const snapshot = await get(context, "/annotations/native/files/1/source?bookId=1&page=0");
    await mutate(
      context,
      own.map((entry) => ({
        operationId: randomUUID(),
        clientId: entry.clientId,
        annotationId: entry.id,
        bookId: 1,
        baseVersion: entry.version,
        action: "delete",
        payload: { sourceRevision: snapshot.sourceRevision, pageFingerprint: snapshot.pageFingerprint },
      })),
      Math.min(30_000, Math.max(1, deadline - Date.now())),
    );
  }
  throw new Error("Source fixture cleanup exceeded 2000 rows");
}

const test = base.extend({
  inkFixture: [
    async ({}, use, info) => {
      const context = await connect();
      const uuids = new Set(Array.from({ length: 1102 }, () => randomUUID()));
      const clients = [...uuids];
      const created = [];
      const initial = await get(context, route());
      // An isolated source lease keeps all pre-existing groups in the first cleanup window.
      expect(initial.total).toBeLessThan(100);
      const original = await bytes(context);
      const progress = await get(context, "/books/files/1/progress");
      expect((await context.request.post(`${api}/__faults/source-pdf/source/1/snapshot`, { headers: context.headers })).status()).toBe(204);
      const setupDeadline = Date.now() + 420_000;
      try {
        for (let offset = 0; offset < 1101; offset += 100) {
          if (Date.now() >= setupDeadline) throw new Error("Source fixture creation exceeded its finite budget");
          const snapshot = await get(context, "/annotations/native/files/1/source?bookId=1&page=0");
          expect(snapshot.canEditPdfInk).toBe(true);
          created.push(
            ...(await mutate(
              context,
              clients.slice(offset, Math.min(offset + 100, 1101)).map((clientId, local) => ({
                operationId: randomUUID(),
                clientId,
                bookId: 1,
                baseVersion: 0,
                action: "create",
                payload: payload(offset + local, snapshot),
              })),
              Math.min(30_000, Math.max(1, setupDeadline - Date.now())),
            )),
          );
        }
        await use({
          context,
          clients,
          created,
          initial,
          async addRemote() {
            const snapshot = await get(context, "/annotations/native/files/1/source?bookId=1&page=0");
            return (
              await mutate(context, [
                { operationId: randomUUID(), clientId: clients[1101], bookId: 1, baseVersion: 0, action: "create", payload: payload(1101, snapshot) },
              ])
            )[0];
          },
        });
      } finally {
        // This context outlives a canceled browser test and never deletes by a shared marker.
        const errors = [];
        const attempt = async (name, work) => {
          try {
            await work();
          } catch (error) {
            errors.push({ name, error: error.message });
          }
        };
        await attempt("UUID cleanup", () => cleanup(context, uuids, initial, Date.now() + 180_000));
        await attempt("source restore", async () => {
          expect((await context.request.post(`${api}/__faults/source-pdf/source/1/restore`, { headers: context.headers })).status()).toBe(204);
          expect(hash(await bytes(context))).toBe(hash(original));
        });
        await attempt("progress restore", async () => {
          expect(
            (
              await context.request.post(`${api}/books/files/1/progress`, {
                headers: context.headers,
                data: { source: "text", percentage: progress.percentage, pageNumber: progress.pageNumber, cfi: progress.cfi },
              })
            ).status(),
          ).toBe(201);
          const restored = await get(context, "/books/files/1/progress");
          expect([restored.percentage, restored.pageNumber, restored.cfi]).toEqual([progress.percentage, progress.pageNumber, progress.cfi]);
        });
        await writeFile(
          info.outputPath("source-window-fixture-cleanup.json"),
          `${JSON.stringify(
            {
              clientIds: clients,
              sourceBeforeSha256: hash(original),
              originalProgress: {
                percentage: progress.percentage,
                pageNumber: progress.pageNumber,
                cfi: progress.cfi,
              },
              errors,
            },
            null,
            2,
          )}\n`,
        );
        await context.request.dispose();
        expect(errors, "Fixture cleanup must restore exact source bytes/progress and preserve unrelated groups").toEqual([]);
      }
    },
    { timeout: 720_000 },
  ],
});

async function signIn(page) {
  await page.goto("/login");
  await page.locator("#username").fill("ipad-owner");
  await page.locator("#password").fill("IpadFixture123");
  const login = page.waitForResponse((entry) => entry.url().endsWith("/auth/login") && entry.request().method() === "POST");
  await page.getByRole("button", { name: "Sign in", exact: true }).click();
  expect((await login).status()).toBe(200);
  await expect(page).not.toHaveURL(/\/login/);
}

async function artifact(context, info, state) {
  const delivered = await bytes(context);
  const path = info.outputPath(`${state}.pdf`);
  await writeFile(path, delivered);
  const document = await PDFDocument.load(delivered);
  expect(document.getPageCount()).toBe(3);
  expect(document.getPage(0).getSize()).toEqual({ width: 600, height: 800 });
  const ids = document.getPages().flatMap((page) =>
    (page.node.Annots()?.asArray() ?? []).flatMap((reference) => {
      const id = document.context.lookup(reference).lookupMaybe(PDFName.of("BookOrbitAnnotationId"), PDFNumber)?.asNumber();
      return id == null ? [] : [id];
    }),
  );
  await execute(
    process.env.IPAD_PDFTOPPM ?? "/opt/homebrew/bin/pdftoppm",
    ["-f", "1", "-singlefile", "-scale-to-x", "600", "-scale-to-y", "800", "-png", path, info.outputPath(state)],
    { timeout: 30_000 },
  );
  const pixel = async (x, y) => [
    ...(await sharp(info.outputPath(`${state}.png`))
      .extract({ left: x, top: y, width: 1, height: 1 })
      .removeAlpha()
      .raw()
      .toBuffer()),
  ];
  return { ids, pixel };
}

function mutation(page, action, id) {
  return page.waitForResponse(
    (entry) =>
      entry.url().endsWith("/annotations/native/source-ink/1/1/operations") &&
      entry.request().method() === "POST" &&
      entry
        .request()
        .postDataJSON()
        ?.operations.some((operation) => operation.action === action && operation.annotationId === id),
  );
}

async function windowShows(page, pager, direction, number) {
  const response = page.waitForResponse((entry) => {
    const url = new URL(entry.url());
    return (
      url.pathname.endsWith("/annotations/native/source-ink/window") &&
      url.searchParams.get("page") === "0" &&
      url.searchParams.get("window") === String(number)
    );
  });
  await pager.getByRole("button", { name: `${direction} page`, exact: true }).click();
  const window = await json(await response);
  expect(window.items.length).toBeLessThanOrEqual(100);
  expect(window.window).toBe(number);
  await expect(page.getByTestId(`source-ink-${window.items[0].id}`)).toBeVisible();
  await expect(page.locator('[data-page-index="0"] [data-testid^="source-ink-"]')).toHaveCount(window.items.length);
  await expect(page.getByRole("spinbutton", { name: "Current page", exact: true })).toHaveValue("1");
  return window;
}

// Authenticated protocol strokes exercise real publication, never physical Pencil input.
test("IPAD-E02-A03-source-window-web: oldest shared source ink stays selectable and undoable beyond one thousand same-page groups", async ({
  page,
  inkFixture,
}, info) => {
  page.setDefaultTimeout(15_000);
  const { context, created, initial } = inkFixture;
  const oldest = created[0];
  await signIn(page);
  await page.goto("/read/1/1?format=pdf&page=1");
  await expect(page.getByRole("spinbutton", { name: "Current page", exact: true })).toHaveValue("1");
  const pager = page.getByTestId("source-ink-pagination");
  await expect(pager).toBeVisible();
  await expect(page.getByTestId(`source-ink-${oldest.id}`)).toBeVisible();
  const first = await get(context, route());
  expect(first.total).toBe(initial.total + 1101);
  expect(first.items.map((entry) => entry.id)).toContain(oldest.id);
  await expect(page.locator('[data-page-index="0"] [data-testid^="source-ink-"]')).toHaveCount(first.items.length);
  const seeded = await artifact(context, info, "source-window-seeded");
  expect(seeded.ids).toContain(oldest.id);
  expect(await seeded.pixel(120, 500)).toEqual([255, 0, 0]);
  const ink = page.getByTestId(`source-ink-${oldest.id}`);
  await ink.click({ button: "right" });
  await expect(page.getByRole("menuitem", { name: "Delete", exact: true })).toBeVisible();
  await captureAnnotationVisual(page, info, "source-window-oldest-context-menu");
  const deletion = mutation(page, "delete", oldest.id);
  await page.getByRole("menuitem", { name: "Delete", exact: true }).click();
  const deleteResponse = await deletion;
  const deleted = (await json(deleteResponse)).results[0];
  expect(deleted.status).toBe("applied");
  expect(deleted.publication.status).toBe("published");
  await expect(ink).toHaveCount(0);
  const removed = await artifact(context, info, "source-window-oldest-deleted");
  expect(removed.ids).not.toContain(oldest.id);
  expect(await removed.pixel(120, 500)).toEqual([255, 255, 255]);
  const inverse = mutation(page, "restore", oldest.id);
  await page.getByRole("button", { name: "Undo", exact: true }).click();
  const inverseResponse = await inverse;
  const requestBody = inverseResponse.request().postDataJSON().operations[0];
  expect(requestBody.baseVersion).toBe(deleted.annotation.version);
  expect(requestBody.operationId).not.toBe(deleteResponse.request().postDataJSON().operations[0].operationId);
  const restored = (await json(inverseResponse)).results[0];
  expect(restored.status).toBe("applied");
  expect(restored.annotation.version).toBe(deleted.annotation.version + 1);
  expect(restored.publication.status).toBe("published");
  await expect(ink).toBeVisible();
  const returned = await artifact(context, info, "source-window-oldest-restored");
  expect([...returned.ids].sort((left, right) => left - right)).toEqual([...seeded.ids].sort((left, right) => left - right));
  expect(await returned.pixel(120, 500)).toEqual([255, 0, 0]);
  await captureAnnotationVisual(page, info, "source-window-versioned-undo");
  for (let number = 2; number <= 11; number++) await windowShows(page, pager, "Next", number);
  await expect(ink).toHaveCount(0);
  await captureAnnotationVisual(page, info, "source-window-eleventh-window");
  for (let number = 10; number >= 1; number--) await windowShows(page, pager, "Previous", number);
  await expect(ink).toBeVisible();
  const remote = await inkFixture.addRemote();
  const finalWindow = Math.ceil((initial.total + 1102) / 100);
  for (let number = 2; number <= finalWindow; number++) await windowShows(page, pager, "Next", number);
  await expect(page.getByTestId(`source-ink-${remote.id}`)).toBeVisible();
  await captureAnnotationVisual(page, info, "source-window-remote-at-capacity");
  for (let number = finalWindow - 1; number >= 1; number--) await windowShows(page, pager, "Previous", number);
  await expect(ink).toBeVisible();
  await expect(page.getByRole("spinbutton", { name: "Current page", exact: true })).toHaveValue("1");
});
