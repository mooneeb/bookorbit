import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { writeFile } from "node:fs/promises";
import { test, expect } from "@playwright/test";

const execute = promisify(execFile);

async function assertRenderedPassage(page, info, name) {
  const secondPage = page.locator('[data-page-index="1"]').first();
  await expect(secondPage).toBeInViewport({ ratio: 0.75 });
  await expect
    .poll(() => secondPage.locator("img").evaluateAll((images) => images.some((image) => image.complete && image.naturalWidth > 0)))
    .toBe(true);
  const path = info.outputPath(`${name}.png`);
  await page.screenshot({ path });
  const { stdout } = await execute("xcrun", ["swift", "scripts/ipad/recognize-text.swift", path], { timeout: 30_000, maxBuffer: 64 * 1024 });
  const recognized = JSON.parse(stdout);
  await writeFile(info.outputPath(`${name}-recognized-text.json`), `${JSON.stringify(recognized, null, 2)}\n`);
  expect(recognized).toContain("Orbit fixture: passage 2");
}

test("IPAD-E01-A03-web: resume the actual PDF passage saved by a native curl", async ({ page }, info) => {
  await page.goto("/login");
  await page.locator("#username").fill("ipad-reader");
  await page.locator("#password").fill("IpadFixture123");
  const login = page.waitForResponse((response) => response.url().endsWith("/auth/login") && response.request().method() === "POST");
  await page.getByRole("button", { name: "Sign in", exact: true }).click();
  expect((await login).status()).toBe(200);
  await expect(page).not.toHaveURL(/\/login/);
  const position = await page.request.get("/api/v1/books/files/1/progress");
  expect(position.status()).toBe(200);
  const progress = await position.json();
  expect(progress.pageNumber).toBe(2);
  expect(progress.percentage).toBeCloseTo(66.666667, 3);
  const book = await page.request.get("/api/v1/books/1");
  expect(book.status()).toBe(200);
  const metadata = await book.json();
  expect(metadata.id).toBe(1);
  await page.goto("/book/1");
  await expect(page.getByText(metadata.title, { exact: true }).first()).toBeVisible();
  const delivered = page.waitForResponse((response) => new URL(response.url()).pathname === "/api/v1/books/files/1/serve");
  await page.getByRole("button", { name: "Read", exact: true }).click();
  expect((await delivered).ok()).toBe(true);
  const current = page.getByRole("spinbutton", { name: "Current page", exact: true });
  await expect(current).toHaveValue("2");
  await assertRenderedPassage(page, info, "IPAD-E01-A03-native-page-in-web");
  await page.getByRole("button", { name: "Go back", exact: true }).click();
  await expect(page.getByRole("button", { name: "Read", exact: true })).toBeVisible();
  await page.reload();
  await page.getByRole("button", { name: "Read", exact: true }).click();
  await expect(current).toHaveValue("2");
  await assertRenderedPassage(page, info, "IPAD-E01-A03-native-page-reopened-in-web");
});
