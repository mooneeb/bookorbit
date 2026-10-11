import { test, expect } from "@playwright/test";

test("IPAD-E03-A01-scan-web: server-scanned PDF remains readable in the real web library", async ({ page }, info) => {
  await page.goto("/login");
  await page.locator("#username").fill("ipad-owner");
  await page.locator("#password").fill(process.env.IPAD_FIXTURE_PASSWORD ?? "IpadFixture123");
  await page.getByRole("button", { name: "Sign in", exact: true }).click();
  await expect(page).not.toHaveURL(/\/login/);
  const libraries = await (await page.request.get("/api/v1/libraries")).json();
  const library = libraries.find((entry) => entry.name === "E03 scan fixture");
  expect(library).toBeTruthy();
  const response = await page.request.post(`/api/v1/libraries/${library.id}/books`, { data: { pagination: { page: 0, size: 40 } } });
  expect(response.status()).toBe(201);
  const books = await response.json();
  expect(books.total).toBe(1);
  const book = books.items[0];
  await page.goto(`/book/${book.id}`);
  await expect(page.getByText(book.title, { exact: true }).first()).toBeVisible();
  await page.screenshot({ path: info.outputPath("IPAD-E03-A01-scanned-book-web.png") });
  await page.getByRole("button", { name: "Read", exact: true }).click();
  await expect(page.getByRole("spinbutton", { name: "Current page", exact: true })).toBeVisible();
  await expect
    .poll(() => page.locator("[data-page-index] img").evaluateAll((images) => images.some((image) => image.complete && image.naturalWidth > 0)))
    .toBe(true);
  await page.screenshot({ path: info.outputPath("IPAD-E03-A01-scanned-pdf-web-reader.png") });
});
