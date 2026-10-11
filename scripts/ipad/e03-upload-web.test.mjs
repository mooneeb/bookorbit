import { readFile } from "node:fs/promises";
import { test, expect } from "@playwright/test";

test("IPAD-E03-A01-upload-web: reviewed import opens an actual rendered PDF with matching metadata", async ({ page }, info) => {
  const receipt = JSON.parse(await readFile(process.env.IPAD_E03_UPLOAD_RECEIPT_FILE, "utf8"));
  await page.goto("/login");
  await page.locator("#username").fill(receipt.username);
  await page.locator("#password").fill(process.env.IPAD_FIXTURE_PASSWORD ?? "IpadFixture123");
  await page.getByRole("button", { name: "Sign in", exact: true }).click();
  await expect(page).not.toHaveURL(/\/login/);
  await page.goto(`/book/${receipt.bookId}`);
  await expect(page.getByText(receipt.title, { exact: true }).first()).toBeVisible();
  const detail = await page.request.get(`/api/v1/books/${receipt.bookId}`);
  expect(detail.status()).toBe(200);
  expect((await detail.json()).title).toBe(receipt.title);
  await page.screenshot({ path: info.outputPath("IPAD-E03-A01-imported-web-detail.png") });
  const delivered = page.waitForResponse((response) => new URL(response.url()).pathname === `/api/v1/books/files/${receipt.fileId}/serve`);
  await page.getByRole("button", { name: "Read", exact: true }).click();
  expect((await delivered).ok()).toBe(true);
  await expect(page.getByRole("spinbutton", { name: "Current page", exact: true })).toHaveValue("1");
  const firstPage = page.locator('[data-page-index="0"]').first();
  await expect(firstPage).toBeVisible();
  await expect
    .poll(() => firstPage.locator("img").evaluateAll((images) => images.some((image) => image.complete && image.naturalWidth > 0)))
    .toBe(true);
  await page.screenshot({ path: info.outputPath("IPAD-E03-A01-imported-web-reader.png") });
});
