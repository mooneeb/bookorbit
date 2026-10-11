import { test, expect } from "@playwright/test";

test("IPAD-E03-A04-browser: selected native contract metadata survives real web reopening", async ({ page }, info) => {
  await page.goto("/login");
  await page.locator("#username").fill("ipad-editor");
  await page.locator("#password").fill("IpadFixture123");
  await page.getByRole("button", { name: "Sign in", exact: true }).click();
  await expect(page).not.toHaveURL(/\/login/);
  const records = await Promise.all(
    [1, 2, 3].map(async (id) => {
      const response = await page.request.get(`/api/v1/books/${id}`);
      expect(response.status()).toBe(200);
      return response.json();
    }),
  );
  const fields = { publisher: { value: "Browser E03 Selected Press" }, tags: { mode: "add", values: ["E03 cross-client"] } };
  const preview = await page.request.post("/api/v1/books/bulk-edit-metadata/preview", { data: { bookIds: [1, 2], fields } });
  expect(preview.status()).toBe(201);
  const reviewed = await preview.json();
  const applied = await page.request.post("/api/v1/books/bulk-edit-metadata", {
    data: { bookIds: [1, 2], fields, expectedVersions: reviewed.books.map(({ bookId, updatedAt }) => ({ bookId, updatedAt })) },
  });
  expect(applied.status()).toBe(201);
  try {
    for (const id of [1, 2]) {
      await page.goto(`/book/${id}`);
      await page.getByRole("button", { name: "Edit Metadata", exact: true }).click();
      const publisher = page
        .locator("label")
        .filter({ hasText: /^Publisher$/ })
        .locator("..")
        .getByRole("textbox");
      await expect(publisher).toHaveValue("Browser E03 Selected Press");
      await page.reload();
      await expect(publisher).toHaveValue("Browser E03 Selected Press");
      await page.screenshot({ path: info.outputPath(`IPAD-E03-A04-selected-book-${id}-reloaded.png`) });
      await page.goto(`/book/${id}`);
      await page.getByRole("button", { name: "Read", exact: true }).click();
      if (id === 1) {
        await expect(page.getByRole("spinbutton", { name: "Current page", exact: true })).toBeVisible();
        await expect(page.locator('[data-page-index="0"] img').first()).toBeVisible();
      } else {
        await expect.poll(() => page.frames().some((frame) => frame.url().startsWith("blob:"))).toBe(true);
        const chapter = page.frames().find((frame) => frame.url().startsWith("blob:"));
        await expect(chapter.locator("body")).toContainText(/Alpha|chapter/);
      }
      await page.screenshot({ path: info.outputPath(`IPAD-E03-A04-selected-reader-${id}-reopened.png`) });
    }
    const untouched = await (await page.request.get("/api/v1/books/3")).json();
    expect(untouched.publisher).toBe(records[2].publisher);
    expect(untouched.tags).toEqual(records[2].tags);
    const exported = await page.request.post("/api/v1/books/metadata-export/download", { data: { bookIds: [1, 2], format: "json" } });
    expect(exported.status()).toBe(200);
    expect(
      (await exported.json()).items.map(({ bookId, publisher }) => ({ bookId, publisher })).sort((left, right) => left.bookId - right.bookId),
    ).toEqual([
      { bookId: 1, publisher: "Browser E03 Selected Press" },
      { bookId: 2, publisher: "Browser E03 Selected Press" },
    ]);
  } finally {
    for (const original of records.slice(0, 2)) {
      expect(
        (
          await page.request.patch(`/api/v1/books/${original.id}/metadata`, { data: { publisher: original.publisher, tags: original.tags } })
        ).status(),
      ).toBe(200);
    }
  }
});
