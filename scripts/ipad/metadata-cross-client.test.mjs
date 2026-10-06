import { test, expect } from "@playwright/test";

test.use({ actionTimeout: 15_000 });

test("IPAD-E01-A02-web: native bibliographic values and publication lock survive web reopening", async ({ page }, info) => {
  await page.goto("/login");
  await page.locator("#username").fill("ipad-editor");
  await page.locator("#password").fill("IpadFixture123");
  await page.getByRole("button", { name: "Sign in", exact: true }).click();
  await expect(page).not.toHaveURL(/\/login/);
  await page.goto("/book/3");
  await expect(page.getByText("Library book 00002", { exact: true }).first()).toBeVisible();
  const response = await page.request.get("/api/v1/books/3");
  expect(response.status()).toBe(200);
  const book = await response.json();
  expect(book).toMatchObject({
    publisher: "Orbit Press",
    publishedDate: "2024-02-29",
    publishedYear: 2024,
    pageCount: 321,
    language: "eng",
    isbn10: "0140449138",
    isbn13: "9780140449136",
    genres: ["Science Fiction"],
    tags: ["Imported", "Read soon"],
    lockedFields: ["publishedYear"],
  });
  expect(book.authors.map((author) => author.name)).toEqual(["Reader, One", "Léa Noor"]);
  await page.getByRole("button", { name: "Edit Metadata", exact: true }).click();

  function field(label) {
    return page
      .locator("label")
      .filter({ hasText: new RegExp(`^${label}$`) })
      .locator("..");
  }
  async function assertEditor() {
    for (const [label, value] of [
      ["Publisher", "Orbit Press"],
      ["Language", "eng"],
      ["ISBN-10", "0140449138"],
      ["ISBN-13", "9780140449136"],
    ]) {
      const input = field(label).getByRole("textbox");
      await input.scrollIntoViewIfNeeded();
      await expect(input).toBeVisible();
      await expect(input).toHaveValue(value);
    }
    const date = field("Published Date").locator('input[type="date"]');
    const year = field("Year").getByRole("spinbutton");
    await expect(date).toHaveValue("2024-02-29");
    await expect(date).toBeDisabled();
    await expect(year).toHaveValue("2024");
    await expect(year).toBeDisabled();
    await expect(field("Page Count").getByRole("spinbutton")).toHaveValue("321");
    for (const [label, names] of [
      ["Authors", ["Reader, One", "Léa Noor"]],
      ["Genres", ["Science Fiction"]],
      ["Tags", ["Imported", "Read soon"]],
    ]) {
      for (const name of names) {
        const chip = field(label)
          .getByRole("button", { name: `Remove ${name}`, exact: true })
          .locator("..");
        await chip.scrollIntoViewIfNeeded();
        await expect(chip).toBeVisible();
        await expect(chip).toHaveText(`${name} Remove ${name}`);
      }
    }
  }
  await assertEditor();
  await page.screenshot({ path: info.outputPath("IPAD-E01-A02-native-bibliographic-web-editor.png") });
  await page.reload();
  await expect(page).toHaveURL(/tab=edit/);
  await assertEditor();
  await page.screenshot({ path: info.outputPath("IPAD-E01-A02-native-bibliographic-web-reloaded.png") });
});
