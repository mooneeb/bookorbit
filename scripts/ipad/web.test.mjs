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

test("IPAD-E01-A01-web-oidc: controlled provider login reaches the authorized library", async ({ page }) => {
  await page.goto("/login");
  await page.getByRole("button", { name: "Sign in with Test identity provider", exact: true }).click();
  await expect(page).toHaveURL("http://localhost:16484/", { timeout: 15_000 });
  const account = await page.request.get("/api/v1/auth/me");
  expect(account.status()).toBe(200);
  expect((await account.json()).username).toBe("ipad-owner");
  await page.goto("/library/1");
  await expect(page.getByText("(50,000)", { exact: true })).toBeVisible();
});

test("IPAD-E01-A03-web: read the delivered PDF and resume its saved page", async ({ page }, info) => {
  await signIn(page, "ipad-owner");
  const reset = await page.request.post("/api/v1/books/1/reset-reading-state");
  expect(reset.ok()).toBe(true);
  await page.goto("/book/1");
  await page.getByRole("button", { name: "Read", exact: true }).click();
  const current = page.getByRole("spinbutton", { name: "Current page", exact: true });
  await expect(current).toHaveValue("1");
  await expect(page.getByRole("button", { name: "Next page", exact: true })).toBeEnabled();
  await page.screenshot({ path: info.outputPath("IPAD-E01-A03-pdf-page-one.png") });
  const saved = page.waitForResponse(
    (response) =>
      response.url().endsWith("/books/files/1/progress") &&
      response.request().method() === "POST" &&
      response.request().postDataJSON()?.pageNumber === 2,
  );
  await page.getByRole("button", { name: "Next page", exact: true }).click();
  await expect(current).toHaveValue("2");
  const secondPage = page.locator('[data-page-index="1"]').first();
  await expect(secondPage).toBeInViewport({ ratio: 0.75 });
  await page.getByRole("button", { name: "Go back", exact: true }).click();
  await expect(page).toHaveURL(/\/book\/1(?:\?|$)/);
  await expect(page.getByRole("button", { name: "Read", exact: true })).toBeVisible();
  expect((await saved).ok()).toBe(true);
  const position = await page.request.get("/api/v1/books/files/1/progress");
  expect(position.status()).toBe(200);
  expect((await position.json()).pageNumber).toBe(2);
  await page.getByRole("button", { name: "Read", exact: true }).click();
  await expect(current).toHaveValue("2");
  await expect(secondPage).toBeInViewport({ ratio: 0.75 });
  await page.screenshot({ path: info.outputPath("IPAD-E01-A03-pdf-resumed.png") });
});
