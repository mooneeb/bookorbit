import { test, expect } from "@playwright/test";
import { createRequire } from "node:module";

const require = createRequire(new URL("../../server/package.json", import.meta.url));
const { Client } = require("pg");

test("IPAD-E03-A05-entity-web-pagination: bounded group pages, explicit merge preview, mobile return and dismissed restore", async ({
  page,
}, info) => {
  const api = process.env.IPAD_API_BASE ?? "http://localhost:16482/api/v1";
  const db = new Client({ connectionString: process.env.E2E_DATABASE_URL ?? process.env.DATABASE_URL });
  await db.connect();
  const marker = `WebEntityPages-${crypto.randomUUID()}-`;
  const bookID = Number(process.env.IPAD_ENTITY_BOOK_ID ?? "1");
  const login = await page.request.post(`${api}/auth/login`, {
    data: { username: "ipad-editor", password: "IpadFixture123", clientKind: "native", deviceLabel: "Web entity pagination control" },
  });
  expect(login.status()).toBe(200);
  const session = await login.json();
  const headers = { Authorization: `Bearer ${session.accessToken}` };
  const original = await (await page.request.get(`${api}/books/${bookID}`, { headers })).json();
  const previousStatus = (await db.query("SELECT * FROM entity_duplicate_scan_status WHERE entity_type='genre'")).rows[0];
  try {
    const entries = (
      await db.query("INSERT INTO genres(name) SELECT $1 || lpad(n::text, 3, '0') FROM generate_series(1, 109) n RETURNING id,name", [marker])
    ).rows;
    const ids = entries.map((row) => row.id);
    const members = entries.slice(0, 25).sort((a, b) => String(a.id).localeCompare(String(b.id)));
    const target = members[10];
    const source = members[11];
    const hidden = members[24];
    await db.query("INSERT INTO book_genres(book_id,genre_id) SELECT $1,unnest($2::int[])", [bookID, ids]);
    for (let index = 0; index < 24; index++)
      await db.query("INSERT INTO entity_duplicate_candidates(entity_type,entity_id_a,entity_id_b,sim_score) VALUES ('genre',$1,$2,0.999)", [
        ids[index],
        ids[index + 1],
      ]);
    for (let index = 25; index < 67; index += 2)
      await db.query("INSERT INTO entity_duplicate_candidates(entity_type,entity_id_a,entity_id_b,sim_score) VALUES ('genre',$1,$2,0.998)", [
        ids[index],
        ids[index + 1],
      ]);
    await db.query(
      "INSERT INTO entity_duplicate_scan_status(entity_type,is_computing,computed_at,threshold) VALUES ('genre',false,now(),0.1) ON CONFLICT(entity_type) DO UPDATE SET is_computing=false,computed_at=now(),threshold=0.1,error_message=NULL",
    );
    for (let index = 67; index < 109; index += 2) {
      expect(
        (
          await page.request.post(`${api}/entity-manager/genre/duplicates/dismiss`, {
            headers,
            data: { entityIdA: ids[index], entityIdB: ids[index + 1] },
          })
        ).ok(),
      ).toBe(true);
    }
    await page.goto("/login");
    await page.locator("#username").fill("ipad-editor");
    await page.locator("#password").fill("IpadFixture123");
    await page.getByRole("button", { name: "Sign in", exact: true }).click();
    await expect(page).not.toHaveURL(/\/login/);
    await page.goto("/tools/entity-manager");
    await page.getByRole("button", { name: "Entity type", exact: true }).click();
    await page.getByRole("menuitem", { name: "Genres", exact: true }).click();
    await page.getByRole("button", { name: "Find Duplicates", exact: true }).click();
    await expect(page.getByText("10 of 25 entities", { exact: true })).toBeVisible();
    await expect(page.locator('input[name="duplicate-merge-target"]')).toHaveCount(10);
    const nextDetails = page.getByRole("button", { name: "Next group detail page", exact: true });
    await nextDetails.focus();
    await page.keyboard.press("Enter");
    await expect(page.getByText("Group page 2 of 3", { exact: true })).toBeVisible();
    await expect(page.locator("fieldset").getByText(target.name, { exact: true })).toBeVisible();
    await expect(page.locator("fieldset").getByText(members[0].name, { exact: true })).toHaveCount(0);
    await expect(page.getByRole("button", { name: "Preview selected merge", exact: true })).toBeDisabled();
    await page.getByRole("checkbox", { name: `Include ${source.name} in merge`, exact: true }).check();
    await page.getByRole("button", { name: "Preview selected merge", exact: true }).click();
    const preview = page.getByRole("dialog", { name: "Review selected merge", exact: true });
    await expect(preview.getByText(target.name, { exact: true })).toBeVisible();
    await expect(preview.getByText(source.name, { exact: true })).toBeVisible();
    await expect(preview.getByText("1 entity will be merged and removed", { exact: true })).toBeVisible();
    await page.screenshot({ path: info.outputPath("IPAD-E03-A05-web-selected-merge-preview.png") });
    const mergeRequest = page.waitForRequest((request) => request.url().endsWith("/entity-manager/genre/merge") && request.method() === "POST");
    const mergeResponse = page.waitForResponse(
      (response) => response.url().endsWith("/entity-manager/genre/merge") && response.request().method() === "POST",
    );
    await preview.getByRole("button", { name: "Merge 1 into target", exact: true }).click();
    expect((await mergeResponse).status()).toBe(201);
    await expect(preview).toBeHidden();
    expect((await mergeRequest).postDataJSON()).toEqual({ targetEntityId: target.id, sourceEntityIds: [source.id], writeFiles: false });
    const after = await (await page.request.get(`${api}/books/${bookID}`, { headers })).json();
    expect(after.genres.includes(source.name)).toBe(false);
    expect(after.genres.includes(hidden.name)).toBe(true);
    expect(after.files).toEqual(original.files);
    await page.setViewportSize({ width: 390, height: 844 });
    await page.getByRole("button", { name: "Back to groups", exact: true }).click();
    await page.getByRole("button", { name: "Next page", exact: true }).click();
    await expect(page.getByText("2 / 2", { exact: true })).toBeVisible();
    await page.screenshot({ path: info.outputPath("IPAD-E03-A05-web-mobile-group-page.png") });
    await page.getByRole("button", { name: /Show dismissed pairs/ }).click();
    await expect(page.getByText("Dismissed page 1 of 2", { exact: true })).toBeVisible();
    await page.getByRole("button", { name: "Next dismissed page", exact: true }).click();
    await expect(page.getByText("Dismissed page 2 of 2", { exact: true })).toBeVisible();
    const restoreRow = page.locator('[data-testid="dismissed-pair"]').filter({ hasText: `${marker}068` });
    await expect(restoreRow).toBeVisible();
    await restoreRow.getByRole("button", { name: "Restore", exact: true }).click();
    await expect(page.getByText("Dismissed page 1 of 1", { exact: true })).toBeVisible();
    expect(
      (await (await page.request.get(`${api}/entity-manager/genre/duplicates/dismissed-page?page=1&pageSize=20`, { headers })).json()).items.some(
        (pair) => pair.idA === ids[67],
      ),
    ).toBe(false);
    await page.screenshot({ path: info.outputPath("IPAD-E03-A05-web-mobile-dismissed-restored.png") });
  } finally {
    await db.query("DELETE FROM dismissed_duplicate_pairs WHERE entity_type='genre' AND entity_id_a IN (SELECT id FROM genres WHERE name LIKE $1)", [
      `${marker}%`,
    ]);
    await db.query(
      "DELETE FROM entity_duplicate_candidates WHERE entity_type='genre' AND (entity_id_a IN (SELECT id FROM genres WHERE name LIKE $1) OR entity_id_b IN (SELECT id FROM genres WHERE name LIKE $1))",
      [`${marker}%`],
    );
    await db.query("DELETE FROM book_genres WHERE genre_id IN (SELECT id FROM genres WHERE name LIKE $1)", [`${marker}%`]);
    await db.query("DELETE FROM genres WHERE name LIKE $1", [`${marker}%`]);
    if (previousStatus)
      await db.query(
        "UPDATE entity_duplicate_scan_status SET is_computing=$1,computed_at=$2,threshold=$3,total_pairs=$4,total_count=$5,processed_count=$6,error_message=$7 WHERE entity_type='genre'",
        [
          previousStatus.is_computing,
          previousStatus.computed_at,
          previousStatus.threshold,
          previousStatus.total_pairs,
          previousStatus.total_count,
          previousStatus.processed_count,
          previousStatus.error_message,
        ],
      );
    else await db.query("DELETE FROM entity_duplicate_scan_status WHERE entity_type='genre'");
    await page.request.post(`${api}/auth/logout`, { data: { refreshToken: session.refreshToken } });
    await db.end();
  }
});
