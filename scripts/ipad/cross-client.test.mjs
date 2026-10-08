import { test, expect } from "@playwright/test";

async function openRecord(page, path, responsePath, status) {
  const loaded = page.waitForResponse((response) => new URL(response.url()).pathname === responsePath);
  await page.goto(path);
  expect((await loaded).status()).toBe(status);
}

test("IPAD-E01-A02-web: reopen the collection and membership saved through native UI", async ({ page }, info) => {
  await page.goto("/login");
  await page.locator("#username").fill("ipad-owner");
  await page.locator("#password").fill("IpadFixture123");
  await page.getByRole("button", { name: "Sign in", exact: true }).click();
  await expect(page).not.toHaveURL(/\/login/, { timeout: 15_000 });
  const response = await page.request.get("/api/v1/collections/page?mediaType=books&owned=true&q=Native%20reading%20collection&size=40&page=0");
  expect(response.status()).toBe(200);
  const collections = await response.json();
  expect(collections.total).toBe(1);
  expect(collections.items).toHaveLength(1);
  const collection = collections.items[0];
  expect(collection.name).toBe("Native reading collection");
  expect(collection.isOwner).toBe(true);
  expect(collection.isPublic).toBe(false);
  expect(collection.bookCount).toBe(1);
  await openRecord(page, `/collection/${collection.id}`, `/api/v1/collections/${collection.id}/books/query`, 201);
  await expect(page.getByText("Native reading collection", { exact: true }).first()).toBeVisible();
  await expect(page.getByText("Orbit corrected", { exact: true }).first()).toBeVisible();
  await page.screenshot({ path: info.outputPath("IPAD-E01-A02-native-collection-in-web.png") });
  await page.reload();
  await expect(page.getByText("Orbit corrected", { exact: true }).first()).toBeVisible();
  await openRecord(page, "/book/1", "/api/v1/books/1", 200);
  const record = await page.request.get("/api/v1/books/1");
  expect(record.status()).toBe(200);
  expect((await record.json()).collections).toContainEqual(expect.objectContaining({ id: collection.id, name: collection.name }));
  await expect(page.getByText("Orbit corrected", { exact: true }).first()).toBeVisible();
  await expect(page.getByRole("button", { name: "Read", exact: true })).toBeVisible();
  await expect(page.getByText("Native reading collection", { exact: true }).first()).toBeVisible();
  await page.screenshot({ path: info.outputPath("IPAD-E01-A02-native-membership-in-web.png") });
});

test("IPAD-E01-A02-web: reopen native metadata changes and confirm an explicitly cleared subtitle", async ({ page }, info) => {
  await page.goto("/login");
  await page.locator("#username").fill("ipad-owner");
  await page.locator("#password").fill("IpadFixture123");
  await page.getByRole("button", { name: "Sign in", exact: true }).click();
  await expect(page).not.toHaveURL(/\/login/, { timeout: 15_000 });
  await openRecord(page, "/book/1", "/api/v1/books/1", 200);
  await expect(page.getByText("Orbit corrected", { exact: true }).first()).toBeVisible();
  await expect(page.getByRole("button", { name: "Read", exact: true })).toBeVisible();
  await expect(page.getByText("A native correction", { exact: true })).toHaveCount(0);
  const response = await page.request.get("/api/v1/books/1");
  expect(response.status()).toBe(200);
  const book = await response.json();
  expect(book.title).toBe("Orbit corrected");
  expect(book.subtitle).toBeNull();
  expect(book.description).toBe("Description preserved while clearing the subtitle.");
  expect(book.lockedFields).toContain("title");
  await expect(page.getByText("Description preserved while clearing the subtitle.", { exact: true })).toBeVisible();
  await page.screenshot({ path: info.outputPath("IPAD-E01-A02-native-metadata-in-web.png") });
  await page.reload();
  await expect(page.getByText("Orbit corrected", { exact: true }).first()).toBeVisible();
  await page.getByRole("button", { name: "Edit Metadata", exact: true }).click();
  const titleField = page
    .locator("label")
    .filter({ hasText: /^Title$/ })
    .locator("..")
    .getByRole("textbox");
  const subtitleField = page
    .locator("label")
    .filter({ hasText: /^Subtitle$/ })
    .locator("..")
    .getByRole("textbox");
  await expect(titleField).toHaveValue("Orbit corrected");
  await expect(titleField).toBeDisabled();
  await expect(subtitleField).toHaveValue("");
  await page.screenshot({ path: info.outputPath("IPAD-E01-A02-native-metadata-editor-in-web.png") });
});
