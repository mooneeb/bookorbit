import { test, expect } from "@playwright/test";

test.use({ actionTimeout: 15_000 });

test("IPAD-E01-A02-web: cleared bibliographic values survive web reopening", async ({ page }, info) => {
  await page.goto("/login");
  await page.locator("#username").fill("ipad-editor");
  await page.locator("#password").fill("IpadFixture123");
  await page.getByRole("button", { name: "Sign in", exact: true }).click();
  await expect(page).not.toHaveURL(/\/login/);
  await page.goto("/book/7");
  await expect(page.getByText("Library book 00006", { exact: true }).first()).toBeVisible();
  const response = await page.request.get("/api/v1/books/7");
  expect(response.status()).toBe(200);
  const book = await response.json();
  expect(book).toMatchObject({
    title: "Library book 00006",
    publisher: null,
    publishedDate: null,
    publishedYear: null,
    pageCount: null,
    language: null,
    isbn10: null,
    isbn13: null,
    authors: [],
    genres: [],
    tags: [],
    lockedFields: [],
  });
  await page.getByRole("button", { name: "Edit Metadata", exact: true }).click();
  function field(label) {
    return page
      .locator("label")
      .filter({ hasText: new RegExp(`^${label}$`) })
      .locator("..");
  }
  async function assertClearedEditor() {
    for (const label of ["Publisher", "Language", "ISBN-10", "ISBN-13"]) {
      await expect(field(label).getByRole("textbox")).toHaveValue("");
    }
    await expect(field("Published Date").locator('input[type="date"]')).toHaveValue("");
    for (const label of ["Year", "Page Count"]) {
      await expect(field(label).getByRole("spinbutton")).toHaveValue("");
    }
    for (const label of ["Authors", "Genres", "Tags"]) {
      await expect(field(label).getByRole("button", { name: /^Remove / })).toHaveCount(0);
    }
  }
  await assertClearedEditor();
  await page.screenshot({ path: info.outputPath("IPAD-E01-A02-cleared-web-editor.png") });
  await page.reload();
  await expect(page).toHaveURL(/tab=edit/);
  await assertClearedEditor();
  await page.screenshot({ path: info.outputPath("IPAD-E01-A02-cleared-web-reloaded.png") });
});
