import { test, expect } from "@playwright/test";
import { writeFile } from "node:fs/promises";
import { createRequire } from "node:module";

const require = createRequire(new URL("../../server/package.json", import.meta.url));
const sharp = require("sharp");

test.use({ actionTimeout: 15_000 });

test("IPAD-E01-A02-web: native cover revert restores both original images on web reopening", async ({ page }, info) => {
  await page.goto("/login");
  await page.locator("#username").fill("ipad-editor");
  await page.locator("#password").fill("IpadFixture123");
  await page.getByRole("button", { name: "Sign in", exact: true }).click();
  await expect(page).not.toHaveURL(/\/login/);
  await page.goto("/book/6?tab=edit");
  const response = await page.request.get("/api/v1/books/6");
  expect(response.status()).toBe(200);
  const book = await response.json();
  expect(book.coverMedia).toEqual(["ebook", "audio"]);
  expect(book.covers).toMatchObject({
    ebook: { source: "extracted", width: 512, height: 768 },
    audio: { source: "extracted", width: 512, height: 512 },
  });
  const originals = [
    { medium: "ebook", label: "Book cover", caption: "Editing the book cover", width: 512, height: 768, color: [180, 52, 48] },
    { medium: "audio", label: "Audiobook cover", caption: "Editing the audiobook cover", width: 512, height: 512, color: [30, 150, 78] },
  ];
  for (const original of originals) {
    const delivered = await page.request.get(
      `/api/v1/books/6/cover?medium=${original.medium}&strict=true&t=${book.covers[original.medium].updatedAt}`,
    );
    expect(delivered.status()).toBe(200);
    const bytes = await delivered.body();
    await writeFile(info.outputPath(`IPAD-E01-A02-reverted-${original.medium}-delivered.png`), bytes);
    const { data, info: decoded } = await sharp(bytes).removeAlpha().raw().toBuffer({ resolveWithObject: true });
    expect([decoded.width, decoded.height, decoded.channels]).toEqual([original.width, original.height, 3]);
    expect([...data.subarray((10 * decoded.width + 10) * 3, (10 * decoded.width + 10) * 3 + 3)]).toEqual(original.color);
  }
  async function assertOriginals() {
    for (const original of originals) {
      const tile = page.getByRole("radio", { name: original.label, exact: true });
      await tile.click();
      await expect(page.getByText(original.caption, { exact: true })).toBeVisible();
      await expect(page.getByRole("button", { name: "Revert to original", exact: true })).toHaveCount(0);
      const image = tile.locator("img");
      await expect(image).toBeVisible();
      await expect
        .poll(async () => image.evaluate((element) => [element.naturalWidth, element.naturalHeight]))
        .toEqual([original.width, original.height]);
      const color = await image.evaluate((element) => {
        const canvas = document.createElement("canvas");
        canvas.width = element.naturalWidth;
        canvas.height = element.naturalHeight;
        const context = canvas.getContext("2d");
        context.drawImage(element, 0, 0);
        return [...context.getImageData(10, 10, 1, 1).data].slice(0, 3);
      });
      expect(color).toEqual(original.color);
    }
  }
  await assertOriginals();
  await page.screenshot({ path: info.outputPath("IPAD-E01-A02-reverted-covers-web.png") });
  await page.reload();
  await assertOriginals();
  await page.screenshot({ path: info.outputPath("IPAD-E01-A02-reverted-covers-web-reloaded.png") });
});

test("IPAD-E01-A02-web: native original-image upload preserves resolution and transparency on web reopening", async ({ page }, info) => {
  await page.goto("/login");
  await page.locator("#username").fill("ipad-editor");
  await page.locator("#password").fill("IpadFixture123");
  await page.getByRole("button", { name: "Sign in", exact: true }).click();
  await expect(page).not.toHaveURL(/\/login/);
  await page.goto("/book/8?tab=edit");
  const response = await page.request.get("/api/v1/books/8");
  expect(response.status()).toBe(200);
  const book = await response.json();
  expect(book.coverMedia).toEqual(["ebook", "audio"]);
  expect(book.covers).toMatchObject({
    ebook: { source: "custom", width: 2400, height: 3600 },
    audio: { source: "extracted", width: 512, height: 512 },
  });
  const delivered = await page.request.get(`/api/v1/books/8/cover?medium=ebook&strict=true&t=${book.coverVersion}`);
  expect(delivered.status()).toBe(200);
  const bytes = await delivered.body();
  await writeFile(info.outputPath("IPAD-E01-A02-original-custom-delivered.png"), bytes);
  const { data, info: decoded } = await sharp(bytes).ensureAlpha().raw().toBuffer({ resolveWithObject: true });
  expect([decoded.width, decoded.height, decoded.channels]).toEqual([2400, 3600, 4]);
  expect(data[(10 * decoded.width + 10) * 4 + 3]).toBe(0);
  const offset = (10 * decoded.width + 200) * 4;
  expect([...data.subarray(offset, offset + 4)]).toEqual([144, 64, 160, 255]);
  async function assertCustom() {
    const tile = page.getByRole("radio", { name: "Book cover", exact: true });
    await tile.click();
    await expect(page.getByText("Editing the book cover", { exact: true })).toBeVisible();
    await expect(page.getByRole("button", { name: "Revert to original", exact: true })).toBeVisible();
    const image = tile.locator("img");
    await expect(image).toBeVisible();
    await expect.poll(async () => image.evaluate((element) => [element.naturalWidth, element.naturalHeight])).toEqual([2400, 3600]);
    const samples = await image.evaluate((element) => {
      const canvas = document.createElement("canvas");
      canvas.width = element.naturalWidth;
      canvas.height = element.naturalHeight;
      const context = canvas.getContext("2d");
      context.drawImage(element, 0, 0);
      return [[...context.getImageData(10, 10, 1, 1).data], [...context.getImageData(200, 10, 1, 1).data]];
    });
    expect(samples[0][3]).toBe(0);
    expect(samples[1]).toEqual([144, 64, 160, 255]);
    await page.getByRole("radio", { name: "Audiobook cover", exact: true }).click();
    await expect(page.getByRole("button", { name: "Revert to original", exact: true })).toHaveCount(0);
    await expect(page.getByRole("radio", { name: "Audiobook cover", exact: true }).locator("img")).toBeVisible();
  }
  await assertCustom();
  await page.screenshot({ path: info.outputPath("IPAD-E01-A02-original-custom-web.png") });
  await page.reload();
  await assertCustom();
  await page.screenshot({ path: info.outputPath("IPAD-E01-A02-original-custom-web-reloaded.png") });
});
