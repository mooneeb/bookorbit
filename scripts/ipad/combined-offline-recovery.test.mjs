import { createHash, randomUUID } from "node:crypto";
import { createRequire } from "node:module";
import { readFile, writeFile } from "node:fs/promises";
import { test, expect } from "@playwright/test";

const require = createRequire(new URL("../../server/package.json", import.meta.url));
const { PDFDocument, PDFName, PDFNumber } = require("pdf-lib");

async function json(response) {
  expect(response.ok(), String(response.status())).toBe(true);
  return response.json();
}

async function sourcePDF(request, headers, fileID, itemID, info, phase) {
  const response = await request.get(`/api/v1/books/files/${fileID}/serve`, { headers });
  expect(response.status()).toBe(200);
  const bytes = await response.body();
  const document = await PDFDocument.load(bytes);
  expect(document.getPageCount()).toBe(3);
  for (const page of document.getPages()) {
    expect(page.getSize()).toEqual({ width: 600, height: 800 });
    const ids = (page.node.Annots()?.asArray() ?? []).flatMap((reference) => {
      const entry = document.context.lookup(reference);
      const id = entry.lookupMaybe(PDFName.of("BookOrbitAnnotationId"), PDFNumber)?.asNumber();
      return id == null ? [] : [id];
    });
    expect(ids).not.toContain(itemID);
  }
  await writeFile(info.outputPath(`${phase}.pdf`), bytes);
  return bytes;
}

async function openSourcePDF(page, fileID) {
  await page.goto(`/read/6/${fileID}?format=pdf`);
  await expect(page.getByRole("spinbutton", { name: "Current page", exact: true })).toHaveValue("1");
  const firstPage = page.locator('[data-page-index="0"]').first();
  await expect(firstPage).toBeVisible();
  await expect
    .poll(() => firstPage.locator("img").evaluateAll((images) => images.some((image) => image.complete && image.naturalWidth > 0)))
    .toBe(true);
}

test("IPAD-E02-QA5-browser: PDF navigation exposes native source ink and commits only its deletion", async ({ page, request }, info) => {
  test.setTimeout(120_000);
  const fixtureBytes = await readFile(new URL("./fixtures/qa5-native-source-ink.json", import.meta.url));
  expect(fixtureBytes.length).toBeLessThanOrEqual(16 * 1024);
  const fixture = JSON.parse(fixtureBytes);
  expect(fixture.drawing.format).toBe("bookorbit-ink-v1");
  expect(fixture.drawing.nativeData).not.toBe("");
  const credentials = await json(
    await request.post("/api/v1/auth/login", {
      data: { username: "ipad-owner", password: "IpadFixture123", clientKind: "native", deviceLabel: "Isolated QA5 browser gate" },
    }),
  );
  const headers = { Authorization: `Bearer ${credentials.accessToken}` };
  const epubFailures = [];
  page.on("response", (response) => {
    if (new URL(response.url()).pathname === "/api/v1/epub/6/info" && response.status() === 404) {
      epubFailures.push({ url: response.url(), status: response.status() });
    }
  });
  try {
    const source = await request.get("/api/v1/books/files/1/serve", { headers });
    expect(source.status()).toBe(200);
    const uploaded = await json(
      await request.post("/api/v1/books/6/files", {
        headers,
        multipart: { file: { name: `QA5-browser-${randomUUID()}.pdf`, mimeType: "application/pdf", buffer: await source.body() } },
      }),
    );
    const fileID = uploaded.id;
    const snapshot = await json(await request.get(`/api/v1/annotations/native/files/${fileID}/source?bookId=6&page=0`, { headers }));
    const created = await json(
      await request.post("/api/v1/annotations/native/operations", {
        headers,
        data: {
          deviceId: "QA5 captured native drawing fixture",
          operations: [
            {
              operationId: randomUUID(),
              clientId: randomUUID(),
              bookId: 6,
              baseVersion: 0,
              action: "create",
              payload: {
                kind: "pdf_ink",
                bookFileId: fileID,
                text: "",
                sourceRevision: snapshot.sourceRevision,
                pageFingerprint: snapshot.pageFingerprint,
                pdf: fixture.pdf,
                drawing: fixture.drawing,
              },
            },
          ],
        },
      }),
    );
    expect(created.results).toHaveLength(1);
    expect(created.results[0].status).toBe("applied");
    expect(created.results[0].publication.status).toBe("published");
    const original = created.results[0].annotation;
    expect(original.drawing).toEqual(fixture.drawing);
    const before = await request.get(`/api/v1/books/files/${fileID}/serve`, { headers });
    expect(before.status()).toBe(200);
    const beforeBytes = await before.body();
    const beforePDF = await PDFDocument.load(beforeBytes);
    const ids = (beforePDF.getPage(0).node.Annots()?.asArray() ?? []).map((reference) =>
      beforePDF.context.lookup(reference).lookup(PDFName.of("BookOrbitAnnotationId"), PDFNumber).asNumber(),
    );
    expect(ids).toContain(original.id);
    await writeFile(info.outputPath("native-source-ink-before-delete.pdf"), beforeBytes);
    await page.goto("/login");
    await page.locator("#username").fill("ipad-owner");
    await page.locator("#password").fill("IpadFixture123");
    await page.getByRole("button", { name: "Sign in", exact: true }).click();
    await expect(page).not.toHaveURL(/\/login/);
    await openSourcePDF(page, fileID);
    expect(epubFailures).toEqual([]);
    await expect(page.getByText("Failed to fetch EPUB info: 404", { exact: true })).toHaveCount(0);
    const ink = page.getByTestId(`source-ink-${original.id}`);
    await expect(ink).toBeVisible();
    await expect(ink).toBeInViewport();
    await page.screenshot({ path: info.outputPath("native-source-ink-visible.png") });
    await ink.click({ button: "right" });
    const mutation = page.waitForResponse(
      (response) =>
        response.url().endsWith("/operations") &&
        response.request().method() === "POST" &&
        response
          .request()
          .postDataJSON()
          ?.operations?.some((item) => item.action === "delete" && item.annotationId === original.id),
    );
    await page.getByRole("menuitem", { name: "Delete", exact: true }).click();
    expect((await json(await mutation)).results[0].status).toBe("applied");
    await expect(ink).toHaveCount(0);
    const delta = await json(await request.get("/api/v1/annotations/native/delta?bookId=6&cursor=0&limit=100", { headers }));
    expect(delta.hasMore).toBe(false);
    const tombstone = delta.items.find((item) => item.id === original.id);
    expect(tombstone).toBeDefined();
    expect(typeof tombstone.deletedAt).toBe("string");
    expect(tombstone.version).toBeGreaterThan(original.version);
    expect(tombstone.clientId).toBe(original.clientId);
    const afterBytes = await sourcePDF(request, headers, fileID, original.id, info, "browser-committed-ink-delete-source-retained");
    expect(afterBytes).not.toEqual(beforeBytes);
    await page.reload();
    await expect(page.getByRole("spinbutton", { name: "Current page", exact: true })).toHaveValue("1");
    await expect(ink).toHaveCount(0);
    expect(epubFailures).toEqual([]);
    await writeFile(
      info.outputPath("isolated-qa5-authoritative-deletion.json"),
      JSON.stringify(
        {
          fixture: fixture.provenance,
          fileID,
          original,
          tombstone,
          sourcePDFStatus: 200,
          sha256: createHash("sha256").update(afterBytes).digest("hex"),
        },
        null,
        2,
      ),
    );
  } finally {
    await writeFile(info.outputPath("pdf-navigation-observation.json"), JSON.stringify({ epubFailures }, null, 2));
    expect((await request.post("/api/v1/auth/logout", { data: { refreshToken: credentials.refreshToken } })).status()).toBe(200);
  }
});

test("IPAD-E02-QA456-web: one browser collaborates with the combined offline recovery journey", async ({ page, request }, info) => {
  const deadline = Number(process.env.IPAD_QA456_NATIVE_DEADLINE_MS);
  expect(Number.isSafeInteger(deadline), "QA456 browser requires its owning native execution deadline").toBe(true);
  const remaining = deadline - Date.now();
  expect(remaining, "QA456 browser must start within its owning native run").toBeGreaterThan(0);
  test.setTimeout(remaining);
  const checkpoint = `${process.env.IPAD_ANNOTATION_FAULT_URL}/__faults/annotations/checkpoint/`;
  expect(
    (await json(await request.get(`${checkpoint}native-offline-ready`))).reached,
    "Native must complete real offline Read Along playback and save its stale ink edit before the browser launches",
  ).toBe(true);
  const credentials = await json(
    await request.post("/api/v1/auth/login", {
      data: { username: "ipad-owner", password: "IpadFixture123", clientKind: "native", deviceLabel: "Combined journey public observer" },
    }),
  );
  const headers = { Authorization: `Bearer ${credentials.accessToken}` };
  try {
    const detail = await json(await request.get("/api/v1/books/6", { headers }));
    const files = detail.files.filter((file) => file.format.toLowerCase() === "pdf" && file.filename.startsWith("QA456-"));
    expect(files).toHaveLength(1);
    const fileID = files[0].id;
    const source = await json(await request.get(`/api/v1/annotations/native/source-ink?bookId=6&bookFileId=${fileID}&page=0&limit=100`, { headers }));
    expect(source.hasMore).toBe(false);
    const items = source.items.filter((item) => item.kind === "pdf_ink" && item.jumpFileId === fileID && !item.deletedAt);
    expect(items).toHaveLength(1);
    const original = items[0];
    await page.goto("/login");
    await page.locator("#username").fill("ipad-owner");
    await page.locator("#password").fill("IpadFixture123");
    await page.getByRole("button", { name: "Sign in", exact: true }).click();
    await expect(page).not.toHaveURL(/\/login/);
    await openSourcePDF(page, fileID);
    const ink = page.getByTestId(`source-ink-${original.id}`);
    await expect(ink).toBeVisible();
    await ink.click({ button: "right" });
    const mutation = page.waitForResponse(
      (response) =>
        response.url().endsWith("/operations") &&
        response.request().method() === "POST" &&
        response
          .request()
          .postDataJSON()
          ?.operations?.some((item) => item.action === "delete" && item.annotationId === original.id),
    );
    await page.getByRole("menuitem", { name: "Delete", exact: true }).click();
    expect((await json(await mutation)).results[0].status).toBe("applied");
    await expect(ink).toHaveCount(0);
    const committedBytes = await sourcePDF(request, headers, fileID, original.id, info, "browser-committed-delete");
    expect((await request.post(`${checkpoint}browser-delete-done`)).status()).toBe(204);
    await expect.poll(async () => (await json(await request.get(`${checkpoint}native-reconciled`))).reached, { timeout: 180_000 }).toBe(true);
    const delta = await json(await request.get("/api/v1/annotations/native/delta?bookId=6&cursor=0&limit=100", { headers }));
    expect(delta.hasMore).toBe(false);
    const tombstone = delta.items.find((item) => item.id === original.id);
    expect(tombstone.deletedAt).not.toBeNull();
    expect(tombstone.version).toBeGreaterThan(original.version);
    const converged = await sourcePDF(request, headers, fileID, original.id, info, "native-recovery-no-resurrection");
    expect(converged).toEqual(committedBytes);
    await writeFile(
      info.outputPath("canonical-deletion.json"),
      JSON.stringify(
        {
          fileID,
          id: original.id,
          clientID: original.clientId,
          version: tombstone.version,
          sha256: createHash("sha256").update(converged).digest("hex"),
        },
        null,
        2,
      ),
    );
    expect((await request.post(`${checkpoint}browser-verification-done`)).status()).toBe(204);
    await expect.poll(async () => (await json(await request.get(`${checkpoint}journey-complete`))).reached, { timeout: 180_000 }).toBe(true);
    expect((await request.get(`/api/v1/books/files/${fileID}/serve`, { headers })).status()).toBe(404);
  } finally {
    expect((await request.post("/api/v1/auth/logout", { data: { refreshToken: credentials.refreshToken } })).status()).toBe(200);
  }
});
