import { test, expect } from "@playwright/test";

async function signIn(page, username) {
  await page.goto("/login");
  await page.locator("#username").fill(username);
  await page.locator("#password").fill("IpadFixture123");
  const login = page.waitForResponse((response) => response.url().endsWith("/auth/login") && response.request().method() === "POST");
  await page.getByRole("button", { name: "Sign in", exact: true }).click();
  expect((await login).status()).toBe(200);
  await expect(page).not.toHaveURL(/\/login/, { timeout: 15_000 });
}

test("IPAD-E01-A01-web: search the real 50,000-book library and reopen its record", async ({ page }, info) => {
  await signIn(page, "ipad-owner");
  const listing = page.waitForResponse((response) => response.url().includes("/libraries/1/books") && response.request().method() === "POST");
  await page.goto("/library/1");
  const response = await listing;
  expect(response.status()).toBe(201);
  const payload = await response.json();
  expect(payload.total).toBe(50_000);
  expect(payload.items.length).toBeLessThanOrEqual(200);
  expect(payload.page).toBe(0);
  await expect(page.getByText("(50,000)", { exact: true })).toBeVisible();
  await page.screenshot({ path: info.outputPath("IPAD-E01-A01-library-portrait.png") });
  const search = page.waitForResponse(
    (response) =>
      response.url().endsWith("/libraries/1/books") &&
      response.request().method() === "POST" &&
      response.request().postDataJSON()?.q === "Orbit fixture",
  );
  await page.getByRole("textbox", { name: "Search", exact: true }).fill("Orbit fixture");
  const found = await (await search).json();
  expect(found.total).toBe(1);
  expect(found.items.map((book) => book.id)).toEqual([1]);
  await expect(page.getByText("Orbit fixture", { exact: true }).first()).toBeVisible();
  await expect(page.getByText("Library book 00001", { exact: true })).not.toBeVisible();
  await page.goto("/book/1");
  await expect(page.getByText("Orbit fixture", { exact: true }).first()).toBeVisible();
  await page.reload();
  await expect(page.getByText("Orbit fixture", { exact: true }).first()).toBeVisible();
  await page.setViewportSize({ width: 1366, height: 1024 });
  await page.screenshot({ path: info.outputPath("IPAD-E01-A01-detail-landscape.png") });
});

test("IPAD-E01-A05-web: restricted navigation and HTTP enforce library isolation", async ({ page }) => {
  await signIn(page, "ipad-restricted");
  await page.goto("/libraries");
  await expect(page.getByText("Large library", { exact: true })).toHaveCount(0);
  const response = await page.request.get("/api/v1/books/files/1/serve");
  expect(response.status()).toBe(403);
});
