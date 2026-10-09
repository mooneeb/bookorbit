import { createHash } from "node:crypto";
import { createRequire } from "node:module";
import { writeFile } from "node:fs/promises";
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

test("IPAD-E02-QA456-web: one browser collaborates with the combined offline recovery journey", async ({ page, request }, info) => {
  test.setTimeout(660_000);
  const checkpoint = `${process.env.IPAD_ANNOTATION_FAULT_URL}/__faults/annotations/checkpoint/`;
  const credentials = await json(
    await request.post("/api/v1/auth/login", {
      data: { username: "ipad-owner", password: "IpadFixture123", clientKind: "native", deviceLabel: "Combined journey public observer" },
    }),
  );
  const headers = { Authorization: `Bearer ${credentials.accessToken}` };
  try {
    await expect
      .poll(async () => (await json(await request.get(`${checkpoint}native-offline-ready`))).reached, {
        timeout: 420_000,
        message: "Native must complete real offline Read Along playback and save its stale ink edit before deletion",
      })
      .toBe(true);
    const detail = await json(await request.get("/api/v1/books/6", { headers }));
    const files = detail.files.filter((file) => file.format.toLowerCase() === "pdf" && file.filename.startsWith("QA456-"));
    expect(files).toHaveLength(1);
    const fileID = files[0].id;
    const source = await json(await request.get(`/api/v1/annotations/native/source-ink?bookId=6&bookFileId=${fileID}&page=0&limit=100`, { headers }));
    expect(source.hasMore).toBe(false);
    const items = source.items.filter((item) => item.kind === "pdf_ink" && item.bookFileId === fileID && !item.deletedAt);
    expect(items).toHaveLength(1);
    const original = items[0];
    await page.goto("/login");
    await page.locator("#username").fill("ipad-owner");
    await page.locator("#password").fill("IpadFixture123");
    await page.getByRole("button", { name: "Sign in", exact: true }).click();
    await expect(page).not.toHaveURL(/\/login/);
    await page.goto(`/read/6/${fileID}`);
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
