import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { writeFile } from "node:fs/promises";
import { test, expect } from "@playwright/test";

const execute = promisify(execFile);

async function assertRenderedPage(page, info, fileID, state, pageNumber = 2) {
  const index = pageNumber - 1;
  const image = page.getByTestId("cbz-paginated-pages").locator(`img[src$="/cbz/files/${fileID}/pages/${index}"]`);
  await expect(image).toBeInViewport({ ratio: 0.95 });
  await expect.poll(() => image.evaluate((element) => element.complete && element.naturalWidth === 600 && element.naturalHeight === 800)).toBe(true);
  await expect(image).toHaveCSS("opacity", "1");
  await expect(page.locator('input[type="range"][list="cbz-ticks"]')).toHaveValue(String(index));
  const path = info.outputPath(`${state}.png`);
  await page.screenshot({ path });
  const { stdout } = await execute("xcrun", ["swift", "scripts/ipad/recognize-text.swift", path], { timeout: 30_000, maxBuffer: 64 * 1024 });
  const recognized = JSON.parse(stdout);
  await writeFile(info.outputPath(`${state}-recognized-text.json`), `${JSON.stringify(recognized, null, 2)}\n`);
  expect(recognized).toContain(`Orbit comic: page ${pageNumber}`);
}

test("IPAD-E01-A04-comic-web: reopen the actual comic page saved by a native curl", async ({ page }, info) => {
  await page.goto("/login");
  await page.locator("#username").fill("ipad-reader");
  await page.locator("#password").fill("IpadFixture123");
  const login = page.waitForResponse((response) => response.url().endsWith("/auth/login") && response.request().method() === "POST");
  await page.getByRole("button", { name: "Sign in", exact: true }).click();
  expect((await login).status()).toBe(200);
  await expect(page).not.toHaveURL(/\/login/);
  const book = await page.request.get("/api/v1/books/10");
  expect(book.status()).toBe(200);
  const metadata = await book.json();
  expect(metadata.title).toBe("Library book 00009");
  const fileID = metadata.files.find((file) => file.format === "cbz")?.id;
  expect(Number.isSafeInteger(fileID)).toBe(true);
  const saved = await page.request.get(`/api/v1/books/files/${fileID}/progress`);
  expect(saved.status()).toBe(200);
  const progress = await saved.json();
  expect(progress.pageNumber).toBe(2);
  expect(progress.percentage).toBeCloseTo(66.666667, 3);
  expect(progress.koreaderProgress).toBeNull();
  await page.goto("/book/10");
  await expect(page.getByText(metadata.title, { exact: true }).first()).toBeVisible();
  await page.locator('[data-test="cover-actions"]').getByRole("button", { name: "Read", exact: true }).click();
  await assertRenderedPage(page, info, fileID, "IPAD-E01-A04-native-comic-page-in-web");
  await page.getByTestId("cbz-paginated-viewport").click();
  await page.getByRole("button", { name: "Pin menu", exact: true }).click();
  await expect(page.getByRole("button", { name: "Unpin menu", exact: true })).toBeVisible();
  await expect(page.locator('input[type="range"][list="cbz-ticks"]')).toHaveValue("1");
  await page.screenshot({ path: info.outputPath("IPAD-E01-A04-comic-toolbar.png") });
  await expect(page.getByRole("button", { name: "Go back", exact: true })).toBeVisible();
  await page.getByRole("button", { name: "Go back", exact: true }).click();
  await expect(page.locator('[data-test="cover-actions"]').getByRole("button", { name: "Read", exact: true })).toBeVisible();
  await page.reload();
  await page.locator('[data-test="cover-actions"]').getByRole("button", { name: "Read", exact: true }).click();
  await assertRenderedPage(page, info, fileID, "IPAD-E01-A04-native-comic-page-reopened-in-web");
});

test("IPAD-E01-A05-comic-controls: accessible page controls and keyboard navigate actual comic pixels", async ({ page }, info) => {
  await page.goto("/login");
  await page.locator("#username").fill("ipad-reader");
  await page.locator("#password").fill("IpadFixture123");
  const login = page.waitForResponse((response) => response.url().endsWith("/auth/login") && response.request().method() === "POST");
  await page.getByRole("button", { name: "Sign in", exact: true }).click();
  expect((await login).status()).toBe(200);
  await expect(page).not.toHaveURL(/\/login/);
  const bookResponse = await page.request.get("/api/v1/books/10");
  expect(bookResponse.status()).toBe(200);
  const fileID = (await bookResponse.json()).files.find((file) => file.format === "cbz")?.id;
  expect(Number.isSafeInteger(fileID)).toBe(true);
  await page.goto("/book/10");
  await page.locator('[data-test="cover-actions"]').getByRole("button", { name: "Read", exact: true }).click();
  await assertRenderedPage(page, info, fileID, "IPAD-E01-A05-comic-controls-initial-page");
  await page.getByTestId("cbz-paginated-viewport").click();
  await page.getByRole("button", { name: "Pin menu", exact: true }).click();
  await expect(page.getByRole("button", { name: "Unpin menu", exact: true })).toBeVisible();
  await page.screenshot({ path: info.outputPath("IPAD-E01-A05-comic-visible-page-controls.png") });
  for (const name of ["First page", "Previous page", "Next page", "Last page"])
    await expect(page.getByRole("button", { name, exact: true })).toBeVisible();
  await page.getByRole("button", { name: "Previous page", exact: true }).click();
  await assertRenderedPage(page, info, fileID, "IPAD-E01-A05-comic-previous-page", 1);
  await expect(page.getByRole("button", { name: "Previous page", exact: true })).toBeDisabled();
  await page.getByRole("button", { name: "Next page", exact: true }).click();
  await assertRenderedPage(page, info, fileID, "IPAD-E01-A05-comic-next-page", 2);
  await page.getByRole("button", { name: "Last page", exact: true }).click();
  await assertRenderedPage(page, info, fileID, "IPAD-E01-A05-comic-last-page", 3);
  await expect(page.getByRole("button", { name: "Next page", exact: true })).toBeDisabled();
  await page.getByRole("button", { name: "First page", exact: true }).click();
  await assertRenderedPage(page, info, fileID, "IPAD-E01-A05-comic-first-page", 1);
  await page.keyboard.press("ArrowRight");
  await assertRenderedPage(page, info, fileID, "IPAD-E01-A05-comic-keyboard-next-page", 2);
  await page.getByRole("button", { name: "Go back", exact: true }).click();
  await expect(page.locator('[data-test="cover-actions"]').getByRole("button", { name: "Read", exact: true })).toBeVisible();
});
