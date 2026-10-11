import { readFile, writeFile } from "node:fs/promises";
import { test, expect } from "@playwright/test";

const modes = ["booklore:database", "grimmory:database", "audiobookshelf:api", "audiobookshelf:backup", "calibre_web_automated:snapshot"];

async function fixtureFor(mode) {
  const value = process.env.IPAD_MIGRATION_NATIVE_CONFIG;
  expect(value, "Retain real provider fixtures with e03-migration-retain.mjs and source native-fixtures.env").toBeTruthy();
  const fixtures = JSON.parse(value.startsWith("[") ? value : await readFile(value, "utf8"));
  expect(fixtures).toHaveLength(5);
  const fixture = fixtures.find((entry) => `${entry.type}:${entry.mode}` === mode);
  expect(fixture, `Missing retained provider ${mode}`).toBeTruthy();
  expect(fixture.expectedBooks.map((book) => book.format).sort()).toEqual(["cbz", "epub", "mp3", "pdf"]);
  return fixture;
}

async function json(page, path) {
  const response = await page.request.get(`/api/v1/${path}`);
  expect(response.ok(), `${path}: ${response.status()} ${await response.text()}`).toBe(true);
  return response.json();
}

async function openMigration(page) {
  await page.goto("/settings/maintenance");
  await page.getByRole("button", { name: /^(Get Started|Continue Setup|View Details)$/ }).click();
  const dialog = page.getByRole("dialog", { name: "Library Import", exact: true });
  await expect(dialog).toBeVisible();
  return dialog;
}

async function configure(page, dialog, fixture) {
  const reset = dialog.getByRole("button", { name: "Reset Setup", exact: true });
  if (await reset.isVisible()) {
    page.once("dialog", (confirmation) => confirmation.accept());
    await reset.click();
    await expect(dialog.getByTestId("migration-source-fields")).toBeVisible();
  }
  const fields = dialog.getByTestId("migration-source-fields");
  await fields.getByLabel("Source Type", { exact: true }).selectOption(fixture.type);
  await fields.getByLabel("Source Name", { exact: true }).fill(`${fixture.name} browser`);
  const config = fixture.connectionConfig;
  if (fixture.type === "audiobookshelf") {
    await fields.getByRole("radio", { name: config.mode === "backup" ? "Backup file" : "Live API", exact: true }).check();
    if (config.mode === "backup") await fields.getByLabel("Backup file path", { exact: true }).fill(config.backupPath);
    else {
      await fields.getByLabel("Audiobookshelf URL", { exact: true }).fill(config.baseUrl);
      await fields.getByLabel("API token", { exact: true }).fill(config.apiToken);
      await fields.getByLabel("Allow private network access", { exact: true }).check();
    }
  } else if (fixture.type === "calibre_web_automated") {
    await fields.getByLabel("Calibre-Web Automated app.db snapshot", { exact: true }).fill(config.appDatabasePath);
    await fields.getByLabel("Calibre metadata.db snapshot", { exact: true }).fill(config.metadataDatabasePath);
  } else {
    for (const [key, label] of [
      ["host", "Host"],
      ["port", "Port"],
      ["user", "User"],
      ["password", "Password"],
      ["database", "Database"],
      ["mediaRootPath", "Media Root Path"],
    ])
      await fields.getByLabel(label, { exact: true }).fill(String(config[key] ?? ""));
  }
  await dialog.getByRole("button", { name: "Save & Validate", exact: true }).click();
  await expect(dialog.getByRole("button", { name: "Continue to Mappings", exact: true })).toBeEnabled();
  await expect.poll(async () => (await json(page, "migration/state")).active?.source?.name).toBe(`${fixture.name} browser`);
  await dialog.getByRole("button", { name: "Continue to Mappings", exact: true }).click();
  const targetUser = dialog.getByRole("combobox");
  await targetUser.fill("ipad-owner");
  await page.getByRole("option").filter({ hasText: "ipad-owner" }).click();
  const selects = dialog.locator("select");
  await selects.nth(0).selectOption(fixture.sourcePrefix);
  await selects.nth(1).selectOption(fixture.targetPrefix);
  await dialog.getByRole("button", { name: "Save Mappings", exact: true }).click();
  await expect
    .poll(async () => (await json(page, "migration/state")).active?.profile?.pathMappings)
    .toEqual([{ sourcePrefix: fixture.sourcePrefix, targetPrefix: fixture.targetPrefix }]);
  await dialog.getByRole("button", { name: "Continue to Dry Run", exact: true }).click();
  await dialog.getByRole("button", { name: "Run Dry-Run", exact: true }).click();
  await expect
    .poll(async () => (await json(page, "migration/state")).active?.plan?.summary?.matchedBooks, { timeout: 90_000 })
    .toBe(fixture.expectedTotal);
}

async function assertNewerState(page, fixture, baseline) {
  const ebook = fixture.expectedBooks.find((book) => book.format === "epub");
  const progress = await json(page, `books/files/${ebook.fileId}/progress`);
  const book = await json(page, `books/${ebook.id}`);
  expect(book.title).toBe(ebook.title);
  expect(progress.cfi).toMatch(/^epubcfi\(/);
  if (baseline) {
    expect(progress).toEqual(baseline.progress);
    expect(book.readStatus.status).toBe(baseline.status);
  }
  const annotations = await json(page, `books/${ebook.id}/annotations?page=1&pageSize=100`);
  expect(annotations.items.filter((item) => item.id === fixture.privateNoteId && item.note === fixture.privateNote)).toHaveLength(1);
  if (fixture.importsPassageNote) expect(annotations.items.filter((item) => item.note === "Imported permitted passage note")).toHaveLength(1);
  return { progress, status: book.readStatus.status };
}

async function assertReader(page, book, info, state) {
  await page.goto(`/book/${book.id}`);
  await expect(page.getByText(book.title, { exact: true }).first()).toBeVisible();
  await page.reload();
  const audioStart = book.format === "mp3" ? await json(page, `books/${book.id}/audio-progress`) : null;
  const serve = ["epub", "pdf"].includes(book.format)
    ? page.waitForResponse((response) => {
        const path = new URL(response.url()).pathname;
        return (
          path === `/api/v1/books/files/${book.fileId}/serve` || (book.format === "epub" && path.startsWith(`/api/v1/epub/${book.fileId}/file/`))
        );
      })
    : null;
  await page
    .getByRole("button", { name: book.format === "mp3" ? "Listen" : "Read", exact: true })
    .last()
    .click();
  if (book.format === "epub") {
    expect((await serve).ok()).toBe(true);
    await expect.poll(() => page.frames().some((frame) => frame.url().startsWith("blob:"))).toBe(true);
    const chapter = page.frames().find((frame) => frame.url().startsWith("blob:"));
    await expect(chapter.getByText("Migration source passage survives retry.", { exact: true })).toBeVisible();
  } else if (book.format === "pdf") {
    expect((await serve).ok()).toBe(true);
    await expect(page.getByRole("spinbutton", { name: "Current page", exact: true })).toHaveValue("1");
    await expect
      .poll(() => page.locator('[data-page-index="0"] img').evaluateAll((images) => images.some((image) => image.complete && image.naturalWidth > 0)))
      .toBe(true);
  } else if (book.format === "cbz") {
    const image = page.getByTestId("cbz-paginated-pages").locator(`img[src$="/cbz/files/${book.fileId}/pages/0"]`);
    await expect(image).toBeVisible();
    await expect
      .poll(() => image.evaluate((element) => element.complete && element.naturalWidth === 320 && element.naturalHeight === 480))
      .toBe(true);
  } else {
    await expect(page.getByText(book.title, { exact: true }).first()).toBeVisible();
    expect(audioStart.positionSeconds).toBeGreaterThanOrEqual(4);
    const seconds = Math.floor(audioStart.positionSeconds);
    await expect(page.getByText(`${Math.floor(seconds / 60)}:${String(seconds % 60).padStart(2, "0")}`, { exact: true }).first()).toBeVisible();
    const play = page
      .locator("button")
      .filter({ has: page.locator("svg.lucide-play") })
      .first();
    await expect(play).toBeEnabled();
    await play.click();
    await expect.poll(() => page.locator("svg.lucide-pause").count()).toBeGreaterThan(0);
    await page
      .locator("button")
      .filter({ has: page.locator("svg.lucide-pause") })
      .first()
      .click();
    await expect(play).toBeVisible();
  }
  await page.screenshot({ path: info.outputPath(`${state}-${book.format}.png`) });
}

for (const mode of modes) {
  test(`IPAD-E03-A03-browser-${mode}: native outcomes survive web apply, report export and real reader reopening`, async ({ page }, info) => {
    test.setTimeout(300_000);
    const fixture = await fixtureFor(mode);
    await page.goto("/login");
    await page.locator("#username").fill("ipad-owner");
    await page.locator("#password").fill("IpadFixture123");
    await page.getByRole("button", { name: "Sign in", exact: true }).click();
    await expect(page).not.toHaveURL(/\/login/);
    const nativeState = await assertNewerState(page, fixture);
    let dialog = await openMigration(page);
    await configure(page, dialog, fixture);
    await page.screenshot({ path: info.outputPath(`IPAD-E03-A03-${mode}-web-dry-run.png`) });
    await dialog.getByRole("button", { name: "Continue to Migration", exact: true }).click();
    await dialog.getByRole("button", { name: "Start Migration", exact: true }).click();
    const started = page.waitForResponse((response) => response.url().endsWith("/migration/runs/live") && response.request().method() === "POST");
    await dialog.getByRole("button", { name: "Confirm Start", exact: true }).click();
    expect((await started).status()).toBe(201);
    const run = await (await started).json();
    await expect.poll(async () => (await json(page, `migration/runs/${run.id}/progress`)).run.state, { timeout: 120_000 }).toBe("completed");
    await page.reload();
    dialog = await openMigration(page);
    const reportStep = dialog.getByRole("button", { name: /Report/ }).first();
    await reportStep.click();
    await expect(dialog.getByText(`Run #${run.id}`, { exact: true })).toBeVisible();
    await dialog.getByRole("button", { name: /^(Load Full Report|Reload Report)$/ }).click();
    await expect(dialog.getByText("Migration completed with no unresolved books or failures.", { exact: true })).toBeVisible();
    const report = await json(page, `migration/runs/${run.id}/report`);
    expect(report.totals.failed).toBe(0);
    expect(report.details.matchedBooks.length).toBe(Math.min(40, fixture.expectedTotal));
    for (const format of ["json", "csv"]) {
      const downloading = page.waitForEvent("download");
      await dialog.getByRole("button", { name: `Export ${format.toUpperCase()}`, exact: true }).click();
      const download = await downloading;
      const path = info.outputPath(`IPAD-E03-A03-${mode}-report.${format}`);
      await download.saveAs(path);
      const bytes = await readFile(path);
      if (format === "json") {
        const exported = JSON.parse(bytes.toString("utf8"));
        expect(exported.run.id).toBe(run.id);
        expect(exported.details.matchedBooks).toHaveLength(fixture.expectedTotal);
        expect(new Set(exported.details.matchedBooks.map((row) => row.targetBookId)).size).toBe(fixture.expectedTotal);
        for (const book of fixture.expectedBooks)
          expect(exported.details.matchedBooks.some((row) => row.targetBookId === book.id && row.strategy === "file_path")).toBe(true);
      } else
        expect(
          bytes
            .toString("utf8")
            .split("\n")
            .filter((line) => line.startsWith("matched_books,")),
        ).toHaveLength(fixture.expectedTotal);
    }
    await page.screenshot({ path: info.outputPath(`IPAD-E03-A03-${mode}-web-report-reopened.png`) });
    await assertNewerState(page, fixture, nativeState);
    const ebook = fixture.expectedBooks.find((book) => book.format === "epub");
    await page.goto(`/book/${ebook.id}`);
    await page.getByRole("button", { name: "Highlights", exact: true }).click();
    await expect(page.getByText(fixture.privateNote, { exact: true })).toBeVisible();
    if (fixture.importsPassageNote) await expect(page.getByText("Imported permitted passage note", { exact: true })).toBeVisible();
    await page.screenshot({ path: info.outputPath(`IPAD-E03-A03-${mode}-web-preserved-passage-notes.png`) });
    for (const book of fixture.expectedBooks) {
      let deliveryPath = `/api/v1/books/files/${book.fileId}/serve`;
      if (book.format === "mp3") {
        const manifest = await json(page, `audiobooks/${book.id}/manifest`);
        expect(manifest.assets).toHaveLength(1);
        deliveryPath = `/api/v1/audiobooks/${book.id}/assets/${manifest.assets[0].assetId}/content`;
      }
      const delivered = await page.request.get(deliveryPath);
      expect(delivered.ok()).toBe(true);
      expect(await delivered.body()).toEqual(await readFile(book.path));
      await assertReader(page, book, info, `IPAD-E03-A03-${mode}-reader`);
      await assertReader(page, book, info, `IPAD-E03-A03-${mode}-reader-reopened`);
    }
    const listed = await page.request.post(`/api/v1/libraries/${fixture.libraryId}/books`, { data: { pagination: { page: 1, size: 10 } } });
    expect(listed.ok()).toBe(true);
    expect((await listed.json()).total).toBe(fixture.expectedTotal);
    await writeFile(
      info.outputPath(`IPAD-E03-A03-${mode}-evidence.json`),
      JSON.stringify(
        {
          testId: `IPAD-E03-A03-browser-${mode}`,
          runId: run.id,
          matchedBooks: fixture.expectedTotal,
          formats: ["epub", "pdf", "cbz", "mp3"],
          newerProgressBeforeReading: nativeState.progress.percentage,
          nativeReadingStatePreserved: true,
          duplicateImports: 0,
        },
        null,
        2,
      ),
    );
  });
}
