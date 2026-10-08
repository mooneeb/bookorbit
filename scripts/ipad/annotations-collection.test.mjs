import { randomUUID, createHash } from "node:crypto";
import { createRequire } from "node:module";
import { test, expect } from "@playwright/test";
import { captureAnnotationVisual } from "./annotation-visual.mjs";

const prefix = "Web collection proof";
const require = createRequire(new URL("../../server/package.json", import.meta.url));
const sharp = require("sharp");

async function sourceHash(request, headers) {
  const response = await request.get("/api/v1/books/files/1/serve", { headers });
  expect(response.status()).toBe(200);
  return createHash("sha256")
    .update(await response.body())
    .digest("hex");
}

async function pixel(page, x, y) {
  const surface = page.locator('[data-page-index="0"]').first();
  await expect(surface.locator("img").first()).toBeVisible();
  const bounds = await surface.boundingBox();
  const left = Math.round(bounds.x + (x / 600) * bounds.width);
  const top = Math.round(bounds.y + (y / 800) * bounds.height);
  expect(left).toBeLessThan(page.viewportSize().width);
  expect(top).toBeLessThan(page.viewportSize().height);
  const bytes = await sharp(await page.screenshot({ animations: "allow" }))
    .extract({ left, top, width: 1, height: 1 })
    .removeAlpha()
    .raw()
    .toBuffer();
  return [...bytes];
}

async function visibleYellow(page) {
  await expect
    .poll(
      async () => {
        const [r, g, b] = await pixel(page, 545, 100);
        return r > 230 && g > 230 && b < 220;
      },
      { timeout: 15_000 },
    )
    .toBe(true);
}

async function json(response) {
  expect(response.ok(), `${response.status()} ${await response.text()}`).toBe(true);
  return response.json();
}

async function session(request) {
  const result = await json(
    await request.post("/api/v1/auth/login", {
      data: { username: "ipad-reader", password: "IpadFixture123", clientKind: "native", deviceLabel: "Collection acceptance fixture" },
    }),
  );
  return { Authorization: `Bearer ${result.accessToken}` };
}

async function operations(request, headers, items) {
  const result = await json(
    await request.post("/api/v1/annotations/native/operations", { headers, data: { deviceId: "collection-acceptance", operations: items } }),
  );
  expect(result.results).toHaveLength(items.length);
  for (const entry of result.results) expect(entry.status).toBe("applied");
  return result.results.map((entry) => entry.annotation);
}

async function cleanup(request, headers, bookId) {
  for (let batch = 0; batch < 20; batch++) {
    const page = await json(
      await request.get(`/api/v1/annotations/native/hub?bookId=${bookId}&search=${encodeURIComponent(prefix)}&limit=100`, { headers }),
    );
    const selected = page.items.filter((item) => item.note?.startsWith(prefix));
    if (selected.length === 0) return;
    await operations(
      request,
      headers,
      selected.map((item) => ({
        operationId: randomUUID(),
        clientId: item.clientId,
        annotationId: item.id,
        bookId,
        baseVersion: item.version,
        action: "delete",
      })),
    );
  }
  throw new Error("Collection fixture cleanup exceeded its bounded 2000-row allowance");
}

async function seed(request, headers, bookId, payloads) {
  const result = [];
  for (let offset = 0; offset < payloads.length; offset += 100) {
    result.push(
      ...(await operations(
        request,
        headers,
        payloads.slice(offset, offset + 100).map((payload) => ({
          operationId: randomUUID(),
          clientId: randomUUID(),
          bookId,
          baseVersion: 0,
          action: "create",
          payload,
        })),
      )),
    );
  }
  return result;
}

async function signIn(page) {
  await page.goto("/login");
  await page.locator("#username").fill("ipad-reader");
  await page.locator("#password").fill("IpadFixture123");
  const response = page.waitForResponse((entry) => entry.url().endsWith("/auth/login") && entry.request().method() === "POST");
  await page.getByRole("button", { name: "Sign in", exact: true }).click();
  expect((await response).status()).toBe(200);
  await expect(page).not.toHaveURL(/\/login/);
}

test("IPAD-E02-A03-collection: all PDF note windows remain reachable beyond one thousand annotations", async ({ page, request }, info) => {
  page.setDefaultTimeout(10_000);
  const headers = await session(request);
  await cleanup(request, headers, 1);
  const originalSource = await sourceHash(request, headers);
  const originalPosition = await json(await request.get("/api/v1/books/files/1/progress", { headers }));
  try {
    expect(
      (await request.post("/api/v1/books/files/1/progress", { headers, data: { source: "text", percentage: 0, pageNumber: 1, cfi: null } })).status(),
    ).toBe(201);
    await seed(
      request,
      headers,
      1,
      Array.from({ length: 1101 }, (_, index) => {
        const rect = index === 0 ? { x: 520, y: 90, width: 50, height: 20 } : { x: 10 + (index % 490), y: 180 + (index % 400), width: 2, height: 2 };
        return {
          kind: "highlight",
          bookFileId: 1,
          text: `Collection PDF note ${String(index).padStart(4, "0")}`,
          note: `${prefix} PDF ${String(index).padStart(4, "0")}`,
          color: index === 0 ? "#ffff00" : "#dddddd",
          style: "highlight",
          pdf: { page: Math.floor(index / 400), rect, rects: [rect] },
        };
      }),
    );
    const canonical = await json(
      await request.get("/api/v1/books/1/annotations?page=1&pageSize=100&sortBy=position&sortDir=asc&bookFileId=1&excludeSourceInk=true", {
        headers,
      }),
    );
    expect(canonical.total).toBeGreaterThan(1100);
    await signIn(page);
    await page.goto("/book/1");
    const resumed = page.waitForResponse(
      (entry) => new URL(entry.url()).pathname.endsWith("/books/files/1/progress") && entry.request().method() === "GET",
    );
    await page.getByRole("button", { name: "Read", exact: true }).click();
    await (await resumed).finished();
    await page.getByRole("spinbutton", { name: "Current page", exact: true }).fill("1");
    await page.getByRole("spinbutton", { name: "Current page", exact: true }).press("Enter");
    await expect(page.getByRole("spinbutton", { name: "Current page", exact: true })).toHaveValue("1");
    await page.getByRole("tab", { name: "Notes", exact: true }).click();
    const sidebar = page.getByRole("tabpanel", { name: "Notes", exact: true });
    await expect(page.getByText("Collection PDF note 0000", { exact: true })).toBeVisible();
    await expect(sidebar.getByRole("button", { name: "Next page", exact: true })).toBeVisible();
    await visibleYellow(page);
    await captureAnnotationVisual(page, info, "collection-initial-hundred-row-window");
    const moveWindow = async (direction, number) => {
      const response = page.waitForResponse((entry) => {
        const url = new URL(entry.url());
        return url.pathname.endsWith("/books/1/annotations") && url.searchParams.get("page") === String(number) && !url.searchParams.has("pdfPage");
      });
      await sidebar.getByRole("button", { name: `${direction} page`, exact: true }).click();
      const window = await json(await response);
      expect(window.items.length).toBeLessThanOrEqual(100);
      const firstFixture = window.items.find((item) => item.note?.startsWith(prefix));
      expect(firstFixture).toBeTruthy();
      await expect(sidebar.getByText(firstFixture.text, { exact: true })).toBeVisible();
      if (number > 1) await expect(sidebar.getByText("Collection PDF note 0000", { exact: true })).toHaveCount(0);
      await expect(page.getByRole("spinbutton", { name: "Current page", exact: true })).toHaveValue("1");
    };
    for (let number = 2; number <= 11; number++) await moveWindow("Next", number);
    await expect(sidebar.getByRole("button", { name: "Previous page", exact: true })).toBeVisible();
    await visibleYellow(page);
    await captureAnnotationVisual(page, info, "collection-eleventh-window-preserves-active-page");
    for (let number = 10; number >= 1; number--) await moveWindow("Previous", number);
    await expect(sidebar.getByText("Collection PDF note 0000", { exact: true })).toBeVisible();
    await visibleYellow(page);

    const remoteRect = { x: 520, y: 140, width: 50, height: 20 };
    const reflected = page.waitForResponse(async (entry) => {
      if (!entry.url().includes("/annotations/native/delta?") || !entry.url().includes("bookId=1")) return false;
      const delta = await entry.json();
      return delta.items?.some((item) => item.note === `${prefix} PDF remote addition`);
    });
    await seed(request, headers, 1, [
      {
        kind: "highlight",
        bookFileId: 1,
        text: "Collection remote active-page note",
        note: `${prefix} PDF remote addition`,
        color: "#00ff00",
        style: "highlight",
        pdf: { page: 0, rect: remoteRect, rects: [remoteRect] },
      },
    ]);
    await (await reflected).finished();
    await expect
      .poll(
        async () => {
          const [r, g, b] = await pixel(page, 545, 150);
          return r < 220 && g > 230 && b < 220;
        },
        { timeout: 15_000 },
      )
      .toBe(true);
    await visibleYellow(page);
    await captureAnnotationVisual(page, info, "collection-remote-addition-visible-on-active-page");
    for (let number = 2; number <= 11; number++) await moveWindow("Next", number);
    for (let number = 10; number >= 1; number--) await moveWindow("Previous", number);
    await expect(sidebar.getByText("Collection PDF note 0000", { exact: true })).toBeVisible();
    await visibleYellow(page);
  } finally {
    await cleanup(request, headers, 1);
    expect(
      (
        await request.post("/api/v1/books/files/1/progress", {
          headers,
          data: { source: "text", percentage: originalPosition.percentage, pageNumber: originalPosition.pageNumber, cfi: originalPosition.cfi },
        })
      ).status(),
    ).toBe(201);
    expect(await sourceHash(request, headers)).toBe(originalSource);
  }
});

test("IPAD-E02-A01-collection: remote earlier-position EPUB notes refresh a full hundred-row sidebar", async ({ page, request }, info) => {
  page.setDefaultTimeout(10_000);
  const headers = await session(request);
  await cleanup(request, headers, 2);
  const first = "epubcfi(/6/2[c1ref]!/4/2[p1],/1:0,/1:5)";
  const second = "epubcfi(/6/2[c1ref]!/4/4[p2],/1:0,/1:5)";
  const marker = `${prefix} EPUB remote earlier note`;
  try {
    await seed(
      request,
      headers,
      2,
      Array.from({ length: 100 }, (_, index) => ({
        kind: "text_note",
        bookFileId: 2,
        cfi: second,
        text: "First",
        note: `${prefix} EPUB ${String(index).padStart(3, "0")}`,
        color: "#ffff00",
        style: "highlight",
      })),
    );
    expect((await request.post("/api/v1/books/files/2/progress", { headers, data: { source: "text", percentage: 0, cfi: first } })).status()).toBe(
      201,
    );
    await signIn(page);
    const loaded = page.waitForResponse((entry) => entry.url().includes("/books/2/annotations?") && entry.request().method() === "GET");
    await page.goto("/read/2/2");
    expect((await json(await loaded)).items).toHaveLength(100);
    await expect.poll(() => page.frames().some((frame) => frame.url().startsWith("blob:"))).toBe(true);
    const chapter = page.frames().find((frame) => frame.url().startsWith("blob:"));
    await expect(chapter.getByText("Alpha 😀 café omega.", { exact: true })).toBeVisible();
    await expect(page.getByRole("button", { name: "Table of contents", exact: true })).toBeAttached();
    await page.keyboard.press("t");
    await page.getByRole("button", { name: "Highlights", exact: true }).click();
    await expect(page.getByText(`${prefix} EPUB 000`, { exact: true })).toBeVisible();
    await captureAnnotationVisual(page, info, "collection-epub-full-hundred-row-window");
    const reflected = page.waitForResponse(async (entry) => {
      if (!entry.url().includes("/annotations/native/delta?") || !entry.url().includes("bookId=2")) return false;
      return (await entry.json()).items?.some((item) => item.note === marker);
    });
    const [remote] = await seed(request, headers, 2, [
      {
        kind: "text_note",
        bookFileId: 2,
        cfi: first,
        text: "Alpha",
        note: marker,
        color: "#00ff00",
        style: "highlight",
      },
    ]);
    const canonical = await json(
      await request.get("/api/v1/books/2/annotations?page=1&pageSize=100&sortBy=position&sortDir=asc&bookFileId=2", { headers }),
    );
    expect(canonical.items.some((item) => item.id === remote.id)).toBe(true);
    await (await reflected).finished();
    await expect(page.getByText(marker, { exact: true })).toBeVisible({ timeout: 10_000 });
    await captureAnnotationVisual(page, info, "collection-epub-overflow-refetch-shows-remote-note");
  } finally {
    await cleanup(request, headers, 2);
  }
});
