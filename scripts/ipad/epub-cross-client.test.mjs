import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { writeFile } from "node:fs/promises";
import { test, expect } from "@playwright/test";

const execute = promisify(execFile);

async function assertVisibleContent(page, locate) {
  await expect
    .poll(async () => {
      const visible = await Promise.all(
        page
          .frames()
          .filter((frame) => frame.url().startsWith("blob:"))
          .map((frame) =>
            locate(frame)
              .isVisible()
              .catch(() => false),
          ),
      );
      return visible.some(Boolean);
    })
    .toBe(true);
}

async function assertNarratedSentence(page, id) {
  await assertVisibleContent(page, (frame) => frame.locator(`#${id}.proof-speaking`));
}

async function assertSecondChapter(page, info, name) {
  await expect(page).toHaveURL(/\/read\/2\/2(?:\?|$)/);
  await expect.poll(() => page.frames().some((frame) => frame.url().startsWith("blob:"))).toBe(true);
  for (const frame of page.frames().filter((frame) => frame.url().startsWith("blob:"))) {
    await frame.evaluate(() => document.fonts.ready.then(() => undefined));
  }
  const chapter = page.frames().find((frame) => frame.url().startsWith("blob:"));
  await expect(chapter.getByText("Second chapter begins here.", { exact: true })).toBeVisible();
  await chapter.evaluate(() => new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve))));
  const path = info.outputPath(`${name}.png`);
  await page.screenshot({ path });
  const { stdout } = await execute("xcrun", ["swift", "scripts/ipad/recognize-text.swift", path], { timeout: 30_000, maxBuffer: 64 * 1024 });
  const recognized = JSON.parse(stdout);
  await writeFile(info.outputPath(`${name}-recognized-text.json`), `${JSON.stringify(recognized, null, 2)}\n`);
  expect(recognized).toContain("Second chapter begins here.");
}

test("IPAD-E01-A03-web: resume the actual second EPUB chapter saved by native passage selection", async ({ page }, info) => {
  await page.goto("/login");
  await page.locator("#username").fill("ipad-reader");
  await page.locator("#password").fill("IpadFixture123");
  const login = page.waitForResponse((response) => response.url().endsWith("/auth/login") && response.request().method() === "POST");
  await page.getByRole("button", { name: "Sign in", exact: true }).click();
  expect((await login).status()).toBe(200);
  await expect(page).not.toHaveURL(/\/login/);
  const response = await page.request.get("/api/v1/books/files/2/progress");
  expect(response.status()).toBe(200);
  const progress = await response.json();
  expect(progress.cfi).toBe("epubcfi(/6/4[c2ref]!/4/2[p3],/1:0,/1:6)");
  await writeFile(info.outputPath("IPAD-E01-A03-native-epub-progress.json"), `${JSON.stringify(progress, null, 2)}\n`);
  await page.goto("/book/2");
  await expect(page.getByText("Native renderer proof", { exact: true }).first()).toBeVisible();
  const chapter = page.waitForResponse((result) => {
    const path = new URL(result.url()).pathname;
    return path.startsWith("/api/v1/epub/2/file/") && path.endsWith("/c2.xhtml");
  });
  await page.getByRole("button", { name: "Read", exact: true }).last().click();
  expect((await chapter).ok()).toBe(true);
  await assertSecondChapter(page, info, "IPAD-E01-A03-native-epub-passage-in-web");
  await page.reload();
  await assertSecondChapter(page, info, "IPAD-E01-A03-native-epub-passage-web-reload");
});

test("IPAD-E01-A03/A04-web: a real text turn preserves concurrent narration from another session", async ({ page, request }, info) => {
  const login = await request.post("/api/v1/auth/login", {
    data: { username: "ipad-reader", password: "IpadFixture123", clientKind: "native", deviceLabel: "Web narration concurrency fixture" },
  });
  expect(login.status()).toBe(200);
  const credentials = await login.json();
  const headers = { Authorization: `Bearer ${credentials.accessToken}` };
  const path = "/api/v1/books/files/2/progress";
  let original;
  try {
    const originalResponse = await request.get(path, { headers });
    expect(originalResponse.status()).toBe(200);
    original = await originalResponse.json();
    expect((await request.delete(path, { headers })).status()).toBe(204);
    expect(
      (
        await request.post(path, {
          headers,
          data: { source: "narration", percentage: 10, positionSeconds: 4, mediaOverlayFragment: "p1", mediaOverlaySectionIndex: 0 },
        })
      ).status(),
    ).toBe(201);
    await page.goto("/login");
    await page.locator("#username").fill("ipad-reader");
    await page.locator("#password").fill("IpadFixture123");
    await page.getByRole("button", { name: "Sign in", exact: true }).click();
    await expect(page).not.toHaveURL(/\/login/);
    await page.goto("/book/2");
    const loaded = page.waitForResponse((response) => new URL(response.url()).pathname === path && response.request().method() === "GET");
    await page.getByRole("button", { name: "Read", exact: true }).last().click();
    expect((await (await loaded).json()).positionSeconds).toBe(4);
    await expect.poll(() => page.frames().some((frame) => frame.url().startsWith("blob:"))).toBe(true);
    const firstChapter = page.frames().find((frame) => frame.url().startsWith("blob:"));
    await expect(firstChapter.getByText("Alpha 😀 café omega.", { exact: true })).toBeVisible();
    await firstChapter.evaluate(() => document.fonts.ready.then(() => undefined));
    await page.screenshot({ path: info.outputPath("IPAD-E01-A03-web-older-narration-loaded.png") });
    expect(
      (
        await request.post(path, {
          headers,
          data: { source: "narration", percentage: 30, positionSeconds: 20.5, mediaOverlayFragment: "p4", mediaOverlaySectionIndex: 1 },
        })
      ).status(),
    ).toBe(201);
    const saved = page.waitForResponse((response) => {
      if (new URL(response.url()).pathname !== path || response.request().method() !== "POST") return false;
      const payload = response.request().postDataJSON();
      return payload.source === "text" && typeof payload.cfi === "string" && payload.cfi.includes("/6/4");
    });
    await page.keyboard.press("ArrowRight");
    expect((await saved).status()).toBe(201);
    await assertSecondChapter(page, info, "IPAD-E01-A03-web-concurrent-text-turn");
    const response = await request.get(path, { headers });
    expect(response.status()).toBe(200);
    const progress = await response.json();
    await writeFile(info.outputPath("IPAD-E01-A03-web-concurrent-public-progress.json"), `${JSON.stringify(progress, null, 2)}\n`);
    expect(progress.cfi).toContain("/6/4");
    expect(progress.positionSeconds).toBe(20.5);
    expect(progress.mediaOverlayFragment).toBe("p4");
    expect(progress.mediaOverlaySectionIndex).toBe(1);
    expect(progress.narrationPercentage).toBe(30);
  } finally {
    await page.goto("/book/2");
    if (original) {
      const fields = [
        "percentage",
        "cfi",
        "pageNumber",
        "positionSeconds",
        "mediaOverlayFragment",
        "mediaOverlaySectionIndex",
        "koboLocationSource",
        "koboLocationType",
        "koboLocationValue",
        "koboContentSourceProgressPercent",
        "koreaderProgress",
      ];
      expect(
        (
          await request.post(path, { headers, data: { ...Object.fromEntries(fields.map((field) => [field, original[field]])), source: "text" } })
        ).status(),
      ).toBe(201);
    }
    expect((await request.post("/api/v1/auth/logout", { data: { refreshToken: credentials.refreshToken } })).status()).toBe(200);
  }
});

for (const scenario of [
  { name: "pausing a new narrated sentence then turning a page preserves both positions", delayed: false },
  { name: "a delayed narration acknowledgement cannot overwrite a newer text turn", delayed: true },
]) {
  test(`IPAD-E01-A03/A04-web: ${scenario.name}`, async ({ page }, info) => {
    const path = "/api/v1/books/files/2/progress";
    await page.goto("/login");
    await page.locator("#username").fill("ipad-reader");
    await page.locator("#password").fill("IpadFixture123");
    await page.getByRole("button", { name: "Sign in", exact: true }).click();
    await expect(page).not.toHaveURL(/\/login/);
    const originalResponse = await page.request.get(path);
    expect(originalResponse.status()).toBe(200);
    const original = await originalResponse.json();
    let holdStarted;
    const held = new Promise((resolve) => {
      holdStarted = resolve;
    });
    let holdFinished;
    const released = new Promise((resolve) => {
      holdFinished = resolve;
    });
    if (scenario.delayed) {
      let delayed = false;
      await page.route("**/api/v1/books/files/2/progress", async (route) => {
        const request = route.request();
        const payload = request.method() === "POST" ? request.postDataJSON() : null;
        if (!delayed && payload?.source === "narration" && payload.mediaOverlayFragment === "OPS/c1.xhtml#p2") {
          delayed = true;
          const response = await route.fetch();
          expect(response.status()).toBe(201);
          const started = performance.now();
          holdStarted(started);
          await new Promise((resolve) => setTimeout(resolve, 6_000));
          await route.fulfill({ response });
          await writeFile(
            info.outputPath("IPAD-E01-A03-web-delayed-ack-control.json"),
            `${JSON.stringify({ delayMs: performance.now() - started, status: response.status() }, null, 2)}\n`,
          );
          holdFinished();
        } else {
          await route.continue();
        }
      });
    }
    try {
      expect((await page.request.delete(path)).status()).toBe(204);
      expect(
        (
          await page.request.post(path, {
            data: { source: "text", percentage: 0, cfi: "epubcfi(/6/2[c1ref]!/4/2[p1],/1:0,/1:5)" },
          })
        ).status(),
      ).toBe(201);
      await page.goto("/book/2");
      await page.getByRole("button", { name: "Read", exact: true }).last().click();
      await expect.poll(() => page.frames().some((frame) => frame.url().startsWith("blob:"))).toBe(true);
      const firstChapter = page.frames().find((frame) => frame.url().startsWith("blob:"));
      await expect(firstChapter.getByText("Alpha 😀 café omega.", { exact: true })).toBeVisible();
      await firstChapter.evaluate(() => document.fonts.ready.then(() => undefined));
      await page.keyboard.press("Escape");
      await page.getByRole("button", { name: "Listen with narration", exact: true }).click();
      await assertNarratedSentence(page, "p1");
      await page.screenshot({ path: info.outputPath("IPAD-E01-A04-web-first-narrated-sentence.png") });
      await page.getByRole("button", { name: "Pause narration", exact: true }).click();
      await expect(page.getByRole("button", { name: "Play narration", exact: true })).toBeVisible();
      const sentenceTurnStarted = performance.now();
      await page.getByRole("button", { name: "Next sentence", exact: true }).click();
      await assertNarratedSentence(page, "p2");
      await page.getByRole("button", { name: "Pause narration", exact: true }).click();
      await expect(page.getByRole("button", { name: "Play narration", exact: true })).toBeVisible();
      const saved = page.waitForResponse((response) => {
        if (new URL(response.url()).pathname !== path || response.request().method() !== "POST") return false;
        const payload = response.request().postDataJSON();
        return payload.source === "text" && typeof payload.cfi === "string" && payload.cfi.includes("/6/4");
      });
      await page.keyboard.press("PageDown");
      expect(performance.now() - sentenceTurnStarted).toBeLessThan(2_000);
      if (scenario.delayed) {
        const heldAt = await held;
        const newerSave = page.waitForResponse((response) => {
          if (new URL(response.url()).pathname !== path || response.request().method() !== "POST") return false;
          const payload = response.request().postDataJSON();
          return payload.source === "text" && typeof payload.cfi === "string" && payload.cfi.includes("/6/2");
        });
        await page.keyboard.press("PageUp");
        expect(performance.now() - heldAt).toBeLessThan(2_000);
        await assertVisibleContent(page, (frame) => frame.getByText("Alpha 😀 café omega.", { exact: true }));
        const [olderResponse, newerResponse] = await Promise.all([saved, newerSave, released]);
        expect(olderResponse.status()).toBe(201);
        expect(newerResponse.status()).toBe(201);
        await page.screenshot({ path: info.outputPath("IPAD-E01-A03-web-delayed-ack-newer-text-turn.png") });
      } else {
        expect((await saved).status()).toBe(201);
        await assertSecondChapter(page, info, "IPAD-E01-A03-web-paused-narration-text-turn");
      }
      await expect(page.getByRole("button", { name: "Play narration", exact: true })).toBeVisible();
      const response = await page.request.get(path);
      expect(response.status()).toBe(200);
      const progress = await response.json();
      await writeFile(info.outputPath("IPAD-E01-A03-web-paused-narration-public-progress.json"), `${JSON.stringify(progress, null, 2)}\n`);
      expect(progress.cfi).toContain(scenario.delayed ? "/6/2" : "/6/4");
      expect(progress.mediaOverlayFragment).toBe("OPS/c1.xhtml#p2");
      expect(progress.mediaOverlaySectionIndex).toBe(0);
      expect(progress.narrationUpdatedAt).not.toBeNull();
    } catch (error) {
      await page.screenshot({ path: info.outputPath("IPAD-E01-A03-web-paused-narration-failure.png") });
      throw error;
    } finally {
      if (scenario.delayed) await page.unrouteAll({ behavior: "wait" });
      await page.goto("/book/2");
      const fields = [
        "percentage",
        "cfi",
        "pageNumber",
        "positionSeconds",
        "mediaOverlayFragment",
        "mediaOverlaySectionIndex",
        "koboLocationSource",
        "koboLocationType",
        "koboLocationValue",
        "koboContentSourceProgressPercent",
        "koreaderProgress",
      ];
      expect(
        (
          await page.request.post(path, { data: { ...Object.fromEntries(fields.map((field) => [field, original[field]])), source: "text" } })
        ).status(),
      ).toBe(201);
    }
  });
}
