import { readFile } from "node:fs/promises";
import { test, expect } from "@playwright/test";

async function signIn(page, username) {
  await page.goto("/login");
  await page.locator("#username").fill(username);
  await page.locator("#password").fill("IpadFixture123");
  await page.getByRole("button", { name: "Sign in", exact: true }).click();
  await expect(page).not.toHaveURL(/\/login/);
}

async function fixture() {
  if (!process.env.IPAD_E03_FIXTURE_FILE) throw new Error("IPAD_E03_FIXTURE_FILE is required");
  return JSON.parse(await readFile(process.env.IPAD_E03_FIXTURE_FILE, "utf8"));
}

test("IPAD-E03-A05-maintenance-web: a repaired PDF reopens with private notes, progress and identical source bytes", async ({ page }, info) => {
  const configuration = await fixture();
  const maintenance = configuration.maintenanceHttp;
  await signIn(page, "ipad-reader");
  const response = await page.request.get(`/api/v1/books/${maintenance.missingBookId}`);
  expect(response.status()).toBe(200);
  const book = await response.json();
  expect(book.status).toBe("present");
  expect(book.personalNote).toBe("Private note survives missing-file repair");
  const progress = await page.request.get(`/api/v1/books/files/${maintenance.missingFileId}/progress`);
  expect(progress.status()).toBe(200);
  expect((await progress.json()).pageNumber).toBe(1);
  const file = await page.request.get(`/api/v1/books/files/${maintenance.missingFileId}/serve`);
  expect(file.status()).toBe(200);
  expect(await file.body()).toEqual(await readFile(maintenance.replacementPath));
  await page.goto(`/book/${maintenance.missingBookId}`);
  await expect(page.getByText(book.title, { exact: true }).first()).toBeVisible();
  await page.screenshot({ path: info.outputPath("IPAD-E03-A05-web-repaired-book-detail.png") });
  const served = page.waitForResponse((result) => new URL(result.url()).pathname === `/api/v1/books/files/${maintenance.missingFileId}/serve`);
  await page.getByRole("button", { name: "Read", exact: true }).click();
  expect((await served).ok()).toBe(true);
  const current = page.getByRole("spinbutton", { name: "Current page", exact: true });
  await expect(current).toHaveValue("1");
  const firstPage = page.locator('[data-page-index="0"]').first();
  await expect(firstPage).toBeVisible();
  await expect
    .poll(() => firstPage.locator("img").evaluateAll((images) => images.some((image) => image.complete && image.naturalWidth > 0)))
    .toBe(true);
  await page.screenshot({ path: info.outputPath("IPAD-E03-A05-web-repaired-pdf-reader.png") });
  await page.reload();
  await expect(current).toHaveValue("1");
  await page.screenshot({ path: info.outputPath("IPAD-E03-A05-web-repaired-pdf-reopened.png") });
});

test("IPAD-E03-A05-maintenance-web-denial: repair remains forbidden to a reader role", async ({ page }, info) => {
  const configuration = await fixture();
  const maintenance = configuration.maintenanceHttp;
  await signIn(page, "ipad-reader");
  const denied = await page.request.post("/api/v1/maintenance/missing-resources/files/repair", {
    data: {
      bookId: maintenance.missingBookId,
      fileId: maintenance.missingFileId,
      replacementPath: maintenance.replacementPath,
      previewToken: "stale",
    },
  });
  expect(denied.status()).toBe(403);
  await page.goto(`/book/${maintenance.missingBookId}`);
  await expect(page.getByRole("button", { name: "Read", exact: true })).toBeVisible();
  await page.screenshot({ path: info.outputPath("IPAD-E03-A05-web-reader-permission.png") });
});

test("IPAD-E03-A05-baseline-maintenance-web: native settings are reflected in the actual maintenance form", async ({ page }, info) => {
  await signIn(page, "ipad-owner");
  const response = await page.request.get("/api/v1/app-settings");
  expect(response.status()).toBe(200);
  const settings = await response.json();
  const upload = settings.find((row) => row.key === "max_upload_size_mb");
  const update = settings.find((row) => row.key === "update_check_enabled");
  await page.goto("/settings/library/maintenance");
  await expect(page.getByRole("spinbutton")).toHaveValue(upload.value);
  await expect(page.getByRole("switch")).toHaveAttribute("aria-checked", update.value);
  await expect(page.getByRole("spinbutton")).toHaveAttribute("max", "4096");
  await page.screenshot({ path: info.outputPath("IPAD-E03-A05-baseline-maintenance-web.png") });
});

test("IPAD-E03-A05-baseline-maintenance-admin: a settings administrator can edit upload limits without superuser backfill", async ({
  page,
}, info) => {
  await signIn(page, "ipad-settings-admin");
  await page.goto("/settings/library/maintenance");
  await expect(page.getByRole("spinbutton")).toBeVisible();
  await expect(page.getByRole("switch")).toBeVisible();
  await expect(page.getByRole("button", { name: "Run backfill", exact: true })).toHaveCount(0);
  const response = await page.request.post("/api/v1/achievements/admin/backfill");
  expect(response.status()).toBe(403);
  await page.screenshot({ path: info.outputPath("IPAD-E03-A05-baseline-maintenance-admin.png") });
});
