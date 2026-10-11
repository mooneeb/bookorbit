import { test, expect } from "@playwright/test";
import { writeFile } from "node:fs/promises";
import { createRequire } from "node:module";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import {
  browserContextOptions,
  captureVisual,
  get,
  json,
  nativeHandoff,
  reachableControl,
  saveJSON,
  sha256,
  signIn,
  verifyVisualGate,
} from "./e04-web-helpers.mjs";

test.afterEach(async ({}, info) => verifyVisualGate(info));

function duration(seconds) {
  const hours = Math.floor(seconds / 3600);
  const minutes = Math.round((seconds % 3600) / 60);
  return hours ? `${hours}h ${minutes}m` : minutes ? `${minutes}m` : `${seconds}s`;
}

async function verifyNativeRecord(page, info, handoff) {
  const record = handoff.record ?? handoff;
  await signIn(page, record.username);
  const book = await get(page, `books/${record.bookId}`);
  expect(book.readStatus.status).toBe(record.readStatus);
  expect(book.rating).toBe(record.rating);
  expect(book.personalNote).toBe(record.personalNote);
  await page.goto(`/book/${record.bookId}?tab=details`);
  const review = page.getByText("Your review", { exact: true }).locator("..");
  await expect(review.getByText(record.personalNote, { exact: true })).toBeVisible();
  await captureVisual(page, info, "native-personal-record");

  const sessions = await nativeRecordSessions(page, record);
  await verifyNativeRecordHistory(page, info, record, sessions);
}

async function nativeRecordSessions(page, record) {
  const sessions = await get(page, `books/${record.bookId}/sessions?page=1&pageSize=100`);
  expect(sessions.items.length).toBeLessThanOrEqual(100);
  const manual = sessions.items.filter((entry) => entry.source === record.manualSession.source);
  expect(manual).toHaveLength(1);
  expect(manual[0].durationSeconds).toBe(record.manualSession.durationSeconds);
  const native = sessions.items.filter(
    (entry) => entry.source === record.nativeSession.source && entry.sessionType === record.nativeSession.sessionType,
  );
  expect(native).toHaveLength(1);
  expect(native[0].durationSeconds).toBeGreaterThanOrEqual(record.nativeSession.minimumSeconds);
  expect(native[0].durationSeconds).toBeLessThan(120);
  expect(sessions.stats.totalSessions).toBe(2);
  expect(sessions.stats.totalSeconds).toBe(manual[0].durationSeconds + native[0].durationSeconds);
  return sessions;
}

async function verifyNativeRecordHistory(page, info, record, sessions) {
  const responses = [];
  page.on("response", (response) => {
    if (response.url().includes(`/books/${record.bookId}/sessions`)) responses.push(response);
  });
  const readingLog = page.getByRole("button", { name: "Reading Log", exact: true });
  await expect(readingLog).toBeVisible();
  await readingLog.click();
  const summary = page.getByRole("region", { name: "Reading summary", exact: true });
  await expect(summary.getByText("Total time", { exact: true }).locator("..")).toContainText(duration(sessions.stats.totalSeconds));
  await expect(summary.getByText("Sessions", { exact: true }).locator("..")).toContainText("2");
  await expect(page.getByText("iOS app", { exact: true }).first()).toBeVisible();
  await captureVisual(page, info, "native-session-history-chart", {
    sessionTiming: "Actual native elapsed time, manual session exactly 300 seconds",
  });
  await page.reload();
  const reconnected = await get(page, `books/${record.bookId}/sessions?page=1&pageSize=100`);
  expect(reconnected.stats).toEqual(sessions.stats);
  expect(reconnected.items.map((entry) => entry.id)).toEqual(sessions.items.map((entry) => entry.id));
  expect(responses.length).toBeGreaterThan(0);
  await expect(summary).toBeVisible();
  await expect(summary.getByText("Total time", { exact: true }).locator("..")).toContainText(duration(reconnected.stats.totalSeconds));
  await expect(summary.getByText("Sessions", { exact: true }).locator("..")).toContainText("2");
  const ledger = page.getByRole("region", { name: "Sessions", exact: true });
  await expect(ledger).toBeVisible();
  for (const entry of reconnected.items) {
    const minutes = Math.floor(entry.durationSeconds / 60);
    await expect(ledger.getByText(minutes ? `${minutes}m` : `${entry.durationSeconds}s`, { exact: true })).toBeVisible();
  }
  await expect(page.getByText("iOS app", { exact: true }).first()).toBeVisible();
  await captureVisual(page, info, "reconnected-session-history");
  await saveJSON(info, "native-record-convergence", {
    bookId: record.bookId,
    stats: sessions.stats,
    sources: sessions.items.map(({ source, sessionType, durationSeconds }) => ({ source, sessionType, durationSeconds })),
  });
}

async function verifyNativeStatistics(browser, info, handoff) {
  const expected = handoff.statistics;
  expect(expected, "Statistics native handoff is required for the worked example").toBeTruthy();
  const context = await browser.newContext(browserContextOptions(info));
  try {
    const statisticsPage = await context.newPage();
    await signIn(statisticsPage, expected.username);
    const overview = await get(statisticsPage, "user-statistics/activity-overview");
    expect(overview.snapshot.lastSevenDays.totalSeconds).toBe(expected.totalSeconds);
    expect(overview.snapshot.lastSevenDays.readingSeconds).toBe(600);
    expect(overview.snapshot.lastSevenDays.listeningSeconds).toBe(300);
    expect(overview.rhythm.sessionsCount).toBe(expected.totalSessions);
    expect(overview.goal.completedBooks).toBe(expected.completedBooks);
    expect(overview.goal.goalBooks).toBe(expected.goalBooks);
    expect(overview.sources.slices.find((entry) => entry.bucket === expected.source).totalSeconds).toBe(expected.sourceSeconds);
    await statisticsPage.goto("/statistics?tab=user");
    await expect(statisticsPage.getByRole("button", { name: "My Reading", exact: true })).toBeVisible();
    await reachableControl(statisticsPage, statisticsPage.getByRole("button", { name: "Configure", exact: true }));
    await captureVisual(statisticsPage, info, "worked-example-reading-charts");
    await statisticsPage.getByText("Pace vs Goal", { exact: true }).scrollIntoViewIfNeeded();
    await captureVisual(statisticsPage, info, "native-goal-reading-chart", {
      goalBooks: expected.goalBooks,
      completedBooks: expected.completedBooks,
    });
    await statisticsPage.goto("/");
    await expect(statisticsPage.getByText(`of ${expected.goalBooks}`, { exact: true })).toBeVisible();
    await captureVisual(statisticsPage, info, "native-edited-annual-goal");
    const achievements = await get(statisticsPage, "achievements");
    const earned = achievements.categories
      .flatMap((entry) => entry.achievements)
      .find((entry) => entry.key === expected.earnedAchievementKey || entry.id === expected.earnedAchievementKey);
    expect(earned).toBeTruthy();
    expect(earned.earned).toBe(true);
    await statisticsPage.goto("/achievements");
    await expect(statisticsPage.getByText("Ink Initiate", { exact: true })).toBeVisible();
    await captureVisual(statisticsPage, info, "earned-achievement");
    await saveJSON(info, "worked-example-totals", {
      snapshot: overview.snapshot,
      goal: overview.goal,
      sources: overview.sources,
      achievement: earned,
    });
  } finally {
    await context.close();
  }
}

test("IPAD-E04-A01-web-record-and-statistics: native activity, personal fields, totals, goal and earned achievements converge", async ({
  page,
  browser,
}, info) => {
  const handoff = await nativeHandoff("A01");
  await verifyNativeRecord(page, info, handoff);
  await verifyNativeStatistics(browser, info, handoff);
});

test("IPAD-E04-A01-web-record: native activity, personal fields, session history and reload converge", async ({ page }, info) => {
  const handoff = await nativeHandoff("A01");
  await verifyNativeRecord(page, info, handoff);
});

test("IPAD-E04-A01-web-record-history: native session history and reload converge", async ({ page }, info) => {
  const handoff = await nativeHandoff("A01");
  const record = handoff.record ?? handoff;
  await signIn(page, record.username);
  const sessions = await nativeRecordSessions(page, record);
  await page.goto(`/book/${record.bookId}?tab=details`);
  await verifyNativeRecordHistory(page, info, record, sessions);
});

test("IPAD-E04-A01-web-statistics: native worked-example totals, goal and earned achievements converge", async ({ browser }, info) => {
  const handoff = await nativeHandoff("A01");
  await verifyNativeStatistics(browser, info, handoff);
});

test("IPAD-E04-A03-web-delivery-settings-outcomes: native device and mail configuration and protocol outcomes appear on the current web screens", async ({
  page,
}, info) => {
  const handoff = await nativeHandoff("A03");
  await signIn(page, handoff.username);
  expect(handoff.catalog).toBeTruthy();
  const catalog = handoff.catalog;
  await page.goto("/settings/koreader");
  await expect(page.getByText(catalog.koreaderUsername, { exact: true }).first()).toBeVisible();
  await expect(page.getByText("KOReader Status", { exact: true })).toBeVisible();
  await captureVisual(page, info, "native-koreader-settings");
  await page.goto("/settings/opds");
  await expect(page.getByText(catalog.opdsUsername, { exact: true }).first()).toBeVisible();
  await reachableControl(page, page.getByRole("button", { name: "Add", exact: true }));
  await captureVisual(page, info, "native-opds-account");
  const credentials = await get(page, "opds-users");
  expect(credentials.some((entry) => entry.username === catalog.opdsUsername)).toBe(true);
  expect(JSON.stringify(credentials)).not.toContain(catalog.opdsPassword);

  expect(handoff.kobo).toBeTruthy();
  const kobo = handoff.kobo;
  expect(kobo.username).toEqual(expect.any(String));
  expect(kobo.username).not.toBe(handoff.username);
  expect(kobo.userId).toBeGreaterThan(0);
  expect(kobo.collectionId).toBeGreaterThan(0);
  expect(kobo.entitlementId).toEqual(expect.any(String));
  expect(kobo.tagId).toBe(`col-${kobo.collectionId}`);
  expect(kobo.acknowledgedCatalogPages).toBeGreaterThan(0);
  const koboAccount = await signIn(page, kobo.username);
  expect(koboAccount.id).toBe(kobo.userId);
  expect(koboAccount.isSuperuser).toBe(false);
  expect(koboAccount.permissions).toContain("kobo_sync");
  const collection = await get(page, `collections/${kobo.collectionId}`);
  expect(collection.id).toBe(kobo.collectionId);
  expect(collection.userId).toBe(kobo.userId);
  expect(collection.isOwner).toBe(true);
  expect(collection.name).toBe(kobo.collectionName);
  expect(collection.syncToKobo).toBe(true);
  expect(collection.bookCount).toBe(1);
  const devices = await get(page, "kobo/devices");
  expect(devices).toHaveLength(1);
  const device = devices[0];
  expect(device.name).toBe(kobo.deviceName);
  const koboSettings = await get(page, "kobo/settings");
  expect(koboSettings.twoWayProgressSync).toBe(kobo.twoWayProgressSync);
  expect(koboSettings.syncBookOrbitAnnotationsToKobo).toBe(kobo.syncBookOrbitAnnotationsToKobo);
  const koboState = await get(page, `books/${kobo.bookId}/kobo-state`);
  expect(koboState.eligibleForKoboSync).toBe(true);
  expect(koboState.syncCollections).toEqual([kobo.collectionName]);
  expect(koboState.snapshots).toHaveLength(1);
  expect(koboState.snapshots[0]).toMatchObject({
    deviceId: device.id,
    deviceName: kobo.deviceName,
    inSnapshot: true,
    synced: true,
    pendingDelete: false,
  });
  await page.goto("/settings/kobo");
  await expect(page.getByText(kobo.deviceName, { exact: true })).toBeVisible();
  for (const label of ["Two-way progress sync", "Sync BookOrbit highlights to Kobo"]) {
    await expect(page.getByText(label, { exact: true }).locator("../..").getByRole("switch")).toBeChecked();
  }
  await captureVisual(page, info, "native-kobo-device-settings");
  await page.goto("/settings/kobo?tab=activity");
  const koboHistory = await get(page, "kobo/history?limit=20");
  expect(koboHistory.length).toBeLessThanOrEqual(20);
  expect(koboHistory.every((entry) => entry.deviceId === device.id && entry.deviceName === kobo.deviceName)).toBe(true);
  const koboLabels = { book_download: "Book downloaded", library_sync: "Library checked for updates" };
  for (const event of kobo.expectedActivity) {
    expect(koboHistory.some((entry) => entry.event === event && entry.status === "success")).toBe(true);
    await expect(page.getByText(koboLabels[event], { exact: false }).first()).toBeVisible();
  }
  expect(
    koboHistory.some(
      (entry) => entry.event === "book_download" && entry.status === "success" && entry.counts.bookId === kobo.bookId && entry.counts.downloads === 1,
    ),
  ).toBe(true);
  expect(koboHistory.some((entry) => entry.event === "book_download" && entry.status === "failed")).toBe(true);
  await expect(page.getByText("Failed", { exact: true }).first()).toBeVisible();
  await captureVisual(page, info, "native-kobo-received-artifact-status");
  await saveJSON(info, "native-kobo-owned-delivery", {
    username: koboAccount.username,
    userId: koboAccount.id,
    collection,
    device,
    settings: koboSettings,
    state: koboState,
    history: koboHistory,
    nativeCatalog: {
      bookId: kobo.bookId,
      fileId: kobo.fileId,
      entitlementId: kobo.entitlementId,
      tagId: kobo.tagId,
      acknowledgedCatalogPages: kobo.acknowledgedCatalogPages,
    },
  });
  await signIn(page, handoff.username);

  expect(handoff.email).toBeTruthy();
  await page.goto("/settings/email?tab=providers");
  await expect(page.getByText(handoff.email.providerName, { exact: true })).toBeVisible();
  await captureVisual(page, info, "native-email-provider");
  await page.goto("/settings/email?tab=recipients");
  await expect(page.getByText(handoff.email.recipientName, { exact: true })).toBeVisible();
  await expect(page.getByText(handoff.email.recipientAddress, { exact: true })).toBeVisible();
  await captureVisual(page, info, "native-kindle-recipient");
  await page.goto("/settings/email?tab=history");
  await expect(page.getByText("Sent", { exact: true }).first()).toBeVisible();
  const logs = await get(page, `email/log?bookId=${handoff.email.bookId}&page=0&size=20`);
  expect(logs.length).toBeLessThanOrEqual(20);
  expect(logs.some((entry) => entry.status === "sent" && entry.toEmail === handoff.email.recipientAddress)).toBe(true);
  await captureVisual(page, info, "native-email-server-accepted-history", {
    deliveryBoundary: "Controlled SMTP server acceptance; physical Kindle receipt remains manual",
  });
  await saveJSON(info, "native-delivery-visible-outcomes", {
    opdsUsernames: credentials.map((entry) => entry.username),
    mail: logs.map(({ id, status, toEmail }) => ({ id, status, toEmail })),
  });
});

const require = createRequire(new URL("../../server/package.json", import.meta.url));
const execute = promisify(execFile);

async function catalogPDF(page, catalog, fileId) {
  const headers = { Authorization: `Basic ${Buffer.from(`${catalog.opdsUsername}:${catalog.opdsPassword}`).toString("base64")}` };
  const response = await page.request.get(`/api/v1/opds/${catalog.bookId}/download?fileId=${fileId}`, { headers });
  expect(response.status()).toBe(200);
  expect(response.headers()["content-type"]).toContain("pdf");
  return response.body();
}

async function inspectPDF(bytes, info, state) {
  const { PDFDocument, PDFName, PDFNumber } = require("pdf-lib");
  const path = info.outputPath(`${state}.pdf`);
  await writeFile(path, bytes);
  await info.attach(state, { path, contentType: "application/pdf" });
  const pdf = await PDFDocument.load(bytes);
  const ids = pdf.getPages().flatMap((page) =>
    (page.node.Annots()?.asArray() ?? []).flatMap((reference) => {
      const id = pdf.context.lookup(reference).lookupMaybe(PDFName.of("BookOrbitAnnotationId"), PDFNumber)?.asNumber();
      return id == null ? [] : [id];
    }),
  );
  await execute(
    process.env.IPAD_PDFTOPPM ?? "/opt/homebrew/bin/pdftoppm",
    ["-f", "1", "-singlefile", "-scale-to-x", "600", "-scale-to-y", "800", "-png", path, info.outputPath(state)],
    { timeout: 30_000 },
  );
  const image = info.outputPath(`${state}.png`);
  await info.attach(`${state}-render`, { path: image, contentType: "image/png" });
  return { path, image, ids };
}

test("IPAD-E04-A04-web-current-pdf-redelivery: deleting visible source ink republishes the PDF and OPDS delivers the current rendered bytes", async ({
  page,
}, info) => {
  const handoff = await nativeHandoff("A04");
  await signIn(page, handoff.username);
  const { bookId, fileId, catalog } = handoff;
  expect(catalog, "Native catalog configuration must remain available for redelivery").toBeTruthy();
  const initial = await get(page, `annotations/native/files/${fileId}/source?bookId=${bookId}&page=0`);
  expect(initial.canEditPdfInk).toBe(true);
  expect(handoff.ink, "The browser must delete the same ink item produced through the native UI").toBeTruthy();
  const annotation = { id: handoff.ink.annotationId, version: handoff.ink.version };
  const sourceWithInk = await (await page.request.get(`/api/v1/books/files/${fileId}/serve`)).body();
  const deliveredWithInk = await catalogPDF(page, catalog, fileId);
  expect(sha256(deliveredWithInk)).toBe(sha256(sourceWithInk));
  const marked = await inspectPDF(deliveredWithInk, info, "IPAD-E04-A04-catalog-with-ink");
  expect(marked.ids).toContain(annotation.id);

  await page.goto(`/read/${bookId}/${fileId}?format=pdf&page=1`);
  await expect(page.getByRole("spinbutton", { name: "Current page", exact: true })).toHaveValue("1");
  const ink = page.getByTestId(`source-ink-${annotation.id}`);
  await expect(ink).toBeVisible();
  await ink.click({ button: "right" });
  await reachableControl(page, page.getByRole("menuitem", { name: "Delete", exact: true }));
  await captureVisual(page, info, "source-ink-delete-menu", {
    inputBoundary: "Native UI deterministic Pencil boundary; this does not prove physical Pencil input",
  });
  const mutation = page.waitForResponse(
    (response) =>
      response.url().endsWith(`/annotations/native/source-ink/${bookId}/${fileId}/operations`) &&
      response.request().method() === "POST" &&
      response
        .request()
        .postDataJSON()
        ?.operations.some((entry) => entry.action === "delete" && entry.annotationId === annotation.id),
  );
  await page.getByRole("menuitem", { name: "Delete", exact: true }).click();
  const removed = (await json(await mutation)).results[0];
  expect(removed.status).toBe("applied");
  expect(removed.publication.status).toBe("published");
  await expect(ink).toHaveCount(0);
  await captureVisual(page, info, "source-ink-deleted-reader");
  const snapshot = await get(page, `annotations/native/files/${fileId}/source?bookId=${bookId}&page=0`);
  expect(snapshot.sourceRevision).not.toBe(initial.sourceRevision);
  const sourceWithoutInk = await (await page.request.get(`/api/v1/books/files/${fileId}/serve`)).body();
  const deliveredWithoutInk = await catalogPDF(page, catalog, fileId);
  expect(sha256(deliveredWithoutInk)).toBe(sha256(sourceWithoutInk));
  expect(sha256(deliveredWithoutInk)).not.toBe(sha256(deliveredWithInk));
  const clean = await inspectPDF(deliveredWithoutInk, info, "IPAD-E04-A04-catalog-after-deletion");
  expect(clean.ids).not.toContain(annotation.id);
  const sharp = require("sharp");
  const [markedPixels, cleanPixels] = await Promise.all([marked.image, clean.image].map((path) => sharp(path).removeAlpha().raw().toBuffer()));
  expect(cleanPixels.length).toBe(markedPixels.length);
  let changedPixels = 0;
  for (let index = 0; index < markedPixels.length; index += 3) {
    if ([0, 1, 2].some((channel) => Math.abs(markedPixels[index + channel] - cleanPixels[index + channel]) > 16)) changedPixels++;
  }
  expect(changedPixels, "Independent PDF rendering must show removal of the native visible ink").toBeGreaterThan(10);
  await page.reload();
  await expect(ink).toHaveCount(0);
  await expect(page.getByRole("spinbutton", { name: "Current page", exact: true })).toHaveValue("1");
  await captureVisual(page, info, "redelivered-current-pdf-reconnect");
  await saveJSON(info, "current-catalog-artifact", {
    annotationId: annotation.id,
    sourceRevision: snapshot.sourceRevision,
    withInk: sha256(deliveredWithInk),
    afterDeletion: sha256(deliveredWithoutInk),
    markedRender: marked.image,
    deletedRender: clean.image,
    protocol: "OPDS Basic authenticated real acquisition",
  });
});

async function receiverReceipts(page, receiver) {
  const first = await json(await page.request.get(`${receiver}/receipts?limit=100&offset=0`));
  const total = Math.max(first.hardcover.totalUserBooks, first.hardcover.totalReads, first.readwise.totalHighlights, first.storygraph.totalBooks);
  expect(total, "Controlled receiver inspection has a finite 10,000-record bound").toBeLessThanOrEqual(10_000);
  for (let offset = 100; offset < total; offset += 100) {
    const next = await json(await page.request.get(`${receiver}/receipts?limit=100&offset=${offset}`));
    expect(next.readwise.highlights.length).toBeLessThanOrEqual(100);
    expect(next.hardcover.userBooks.length).toBeLessThanOrEqual(100);
    expect(next.hardcover.reads.length).toBeLessThanOrEqual(100);
    expect(next.storygraph.books.length).toBeLessThanOrEqual(100);
    first.hardcover.userBooks.push(...next.hardcover.userBooks);
    first.hardcover.reads.push(...next.hardcover.reads);
    first.readwise.highlights.push(...next.readwise.highlights);
    first.storygraph.books.push(...next.storygraph.books);
  }
  return first;
}

test("IPAD-E04-A05-web-external-settings-outcomes: native provider settings and verified remote records survive web reconnect and Readwise auth retry", async ({
  page,
  browser,
}, info) => {
  const handoff = await nativeHandoff("A05");
  await signIn(page, handoff.username);
  const receiver = process.env.IPAD_E04_RECEIVER_URL;
  expect(receiver, "Controlled external receiver is required").toBeTruthy();
  const receipts = await receiverReceipts(page, receiver);
  expect(receipts.requests.length).toBeLessThanOrEqual(100);
  expect(handoff.hardcover).toBeTruthy();
  const hardcover = await get(page, "hardcover/settings");
  expect(hardcover.tokenConfigured).toBe(true);
  expect(hardcover.enabled).toBe(handoff.hardcover.enabled);
  await page.goto("/settings/hardcover");
  await expect(page.getByText("Connected", { exact: true })).toBeVisible();
  await reachableControl(page, page.getByRole("button", { name: "Validate token", exact: true }));
  await captureVisual(page, info, "native-hardcover-connection-and-sync");
  for (const id of handoff.hardcover.remoteBookIds)
    expect(receipts.hardcover.userBooks.some((entry) => entry.book_id === id || entry.bookId === id)).toBe(true);

  expect(handoff.storygraph).toBeTruthy();
  const storygraph = await get(page, "storygraph/settings");
  expect(storygraph.cookiesConfigured).toBe(true);
  expect(storygraph.enabled).toBe(handoff.storygraph.enabled);
  await page.goto("/settings/storygraph");
  await expect(page.getByText("Connected", { exact: true })).toBeVisible();
  await expect(page.getByText("Book sync scope", { exact: true })).toBeVisible();
  await captureVisual(page, info, "native-storygraph-mapping-and-result");
  for (const id of handoff.storygraph.remoteBookIds) expect(receipts.storygraph.books.some((entry) => entry.id === id)).toBe(true);

  expect(handoff.readwise).toBeTruthy();
  const readwise = await get(page, "readwise/settings");
  expect(readwise.tokenConfigured).toBe(true);
  expect(readwise.enabled).toBe(handoff.readwise.enabled);
  for (const text of handoff.readwise.expectedHighlightTexts) expect(receipts.readwise.highlights.some((entry) => entry.text === text)).toBe(true);
  for (const text of handoff.excludedTexts ?? []) expect(JSON.stringify(receipts)).not.toContain(text);
  await page.goto("/settings/readwise");
  await expect(page.getByText("Connected", { exact: true })).toBeVisible();
  await reachableControl(page, page.getByRole("button", { name: "Test", exact: true }));
  await captureVisual(page, info, "native-readwise-settings");
  expect((await page.request.post(`${receiver}/control`, { data: { provider: "readwise", mode: "auth", count: 1 } })).ok()).toBe(true);
  await page.getByRole("button", { name: "Test", exact: true }).click();
  await expect(page.getByText("Invalid token", { exact: true })).toBeVisible();
  await captureVisual(page, info, "readwise-provider-auth-error");
  expect((await page.request.post(`${receiver}/control`, { data: { provider: "readwise", mode: "accept" } })).ok()).toBe(true);
  await page.getByRole("button", { name: "Test", exact: true }).click();
  await expect(page.getByText("Valid token", { exact: true })).toBeVisible();
  await captureVisual(page, info, "readwise-provider-auth-retry");
  await page.reload();
  await expect(page.getByText("Connected", { exact: true })).toBeVisible();
  const after = await receiverReceipts(page, receiver);
  expect(after.readwise.totalHighlights).toBe(receipts.readwise.totalHighlights);
  expect(new Set(after.readwise.highlights.map((entry) => entry.id)).size).toBe(after.readwise.highlights.length);
  await captureVisual(page, info, "readwise-settings-reconnect");
  await saveJSON(info, "external-visible-remote-outcomes", {
    hardcover: receipts.hardcover,
    storygraph: receipts.storygraph,
    readwise: receipts.readwise,
    tokenValidationDoesNotCreateHighlights: true,
  });

  const imported = handoff.hardcover.import;
  expect(imported, "The native Hardcover import must hand off its separate account and stable remote history identity").toBeTruthy();
  const importContext = await browser.newContext(browserContextOptions(info));
  try {
    const importPage = await importContext.newPage();
    await signIn(importPage, imported.username);
    const book = await get(importPage, `books/${imported.bookId}`);
    expect(book.readStatus.status).toBe(imported.status);
    const history = await get(importPage, `books/${imported.bookId}/reading-attempts?pageSize=100`);
    expect(history.items.length).toBeLessThanOrEqual(100);
    const remote = history.items.filter((entry) => entry.externalProvider === "hardcover" && entry.externalId === String(imported.externalReadId));
    expect(remote).toHaveLength(1);
    expect(remote[0].startedOn).toBe(imported.startedOn);
    expect(remote[0].endedOn).toBe(imported.endedOn);
    await importPage.goto(`/book/${imported.bookId}?tab=reading-log`);
    await expect(importPage.getByText("Attempts", { exact: true }).first()).toBeVisible();
    await captureVisual(importPage, info, "hardcover-native-import-reading-history");
    await importPage.reload();
    const reconnected = await get(importPage, `books/${imported.bookId}/reading-attempts?pageSize=100`);
    expect(
      reconnected.items.filter((entry) => entry.externalProvider === "hardcover" && entry.externalId === String(imported.externalReadId)),
    ).toHaveLength(1);
    await saveJSON(info, "hardcover-native-import-convergence", { status: book.readStatus.status, externalHistory: remote });
  } finally {
    await importContext.close();
  }
});

test("IPAD-E04-A02-web-privacy-insights: another permitted account sees eligible records and withdrawal immediately denies old access", async ({
  page,
  browser,
}, info) => {
  const handoff = await nativeHandoff("A02");
  const owner = await signIn(page, handoff.username);
  const settings = await get(page, "reading-insights-sharing/me");
  expect(settings.sharingLevel).toBe("detailed");
  await page.goto("/settings/account/privacy");
  await expect(page.getByRole("radio", { name: /Share detailed insights/ })).toBeChecked();
  await reachableControl(page, page.getByRole("button", { name: "Load preview", exact: true }));
  await captureVisual(page, info, "native-detailed-sharing-settings");

  const context = await browser.newContext(browserContextOptions(info));
  try {
    const viewer = await context.newPage();
    await signIn(viewer, handoff.viewerUsername);
    const viewedUserId = handoff.userId ?? owner.id;
    let viewSession;
    const created = viewer.waitForResponse(
      (response) => response.url().endsWith(`/shared-reading-insights/${viewedUserId}/view-sessions`) && response.request().method() === "POST",
    );
    const detailResponse = viewer.waitForResponse((response) => response.url().includes(`/shared-reading-insights/${viewedUserId}/detailed?`));
    await viewer.goto(`/settings/admin/account-activity/${viewedUserId}/insights`);
    viewSession = await json(await created);
    const detail = await json(await detailResponse);
    expect(detail.sharingLevel).toBe("detailed");
    const visibleBookIds = [...detail.topBooks, ...detail.recentBooks].map((entry) => entry.bookId);
    for (const id of handoff.permittedBookIds) expect(visibleBookIds).toContain(id);
    for (const id of handoff.excludedBookIds) expect(visibleBookIds).not.toContain(id);
    const payload = JSON.stringify(detail);
    expect(payload).not.toContain(handoff.privatePersonalNote);
    expect(payload).not.toContain(handoff.privateHighlight);
    for (const title of handoff.excludedBookTitles ?? []) await expect(viewer.getByText(title, { exact: true })).toHaveCount(0);
    await captureVisual(viewer, info, "restricted-viewer-permitted-insights");
    await saveJSON(info, "privacy-filtered-insights", detail);

    await page
      .getByRole("radio", { name: /^Share summary/ })
      .locator("..")
      .click();
    const summaryChange = page.waitForResponse(
      (response) => response.url().endsWith("/reading-insights-sharing/me") && response.request().method() === "PATCH",
    );
    await page.getByRole("dialog").getByRole("button", { name: "Confirm", exact: true }).click();
    expect((await json(await summaryChange)).sharingLevel).toBe("summary");
    const headers = { "x-reading-insights-view-session": viewSession.viewSessionId };
    expect((await viewer.request.get(`/api/v1/shared-reading-insights/${viewedUserId}/detailed?days=90`, { headers })).status()).toBe(403);
    await viewer.reload();
    await expect(viewer.getByText("Reading time", { exact: true })).toBeVisible();
    await expect(viewer.getByText("Most-read books", { exact: true })).toHaveCount(0);
    await expect(viewer.getByText("Recently read", { exact: true })).toHaveCount(0);
    await expect(viewer.getByRole("alert")).toHaveCount(0);
    await captureVisual(viewer, info, "summary-sharing-excludes-record-detail");

    await page
      .getByRole("radio", { name: /^Private/ })
      .locator("..")
      .click();
    const confirmation = page.getByRole("dialog");
    await expect(confirmation.getByText("Stop sharing reading insights?", { exact: true })).toBeVisible();
    await captureVisual(page, info, "privacy-withdrawal-confirmation");
    const changed = page.waitForResponse(
      (response) => response.url().endsWith("/reading-insights-sharing/me") && response.request().method() === "PATCH",
    );
    await confirmation.getByRole("button", { name: "Confirm", exact: true }).click();
    expect((await json(await changed)).sharingLevel).toBe("private");
    expect((await viewer.request.get(`/api/v1/shared-reading-insights/${viewedUserId}/detailed?days=90`, { headers })).status()).toBe(403);
    const privateResponse = viewer.waitForResponse((response) => response.url().endsWith(`/shared-reading-insights/${viewedUserId}/view-sessions`));
    await viewer.reload();
    expect((await privateResponse).status()).toBe(403);
    await expect(viewer.getByRole("alert")).toContainText("This user is not sharing reading insights");
    await captureVisual(viewer, info, "withdrawn-insights-denial");
    for (const id of handoff.excludedBookIds) expect((await viewer.request.get(`/api/v1/books/${id}`)).status()).toBe(403);
    for (const id of handoff.excludedFileIds ?? []) expect((await viewer.request.get(`/api/v1/books/files/${id}/serve`)).status()).toBe(403);
    const restricted = await browser.newContext(browserContextOptions(info));
    try {
      const denied = await restricted.newPage();
      await signIn(denied, "ipad-restricted");
      expect((await denied.request.post(`/api/v1/shared-reading-insights/${viewedUserId}/view-sessions`)).status()).toBe(403);
      await denied.goto("/settings");
      await expect(denied.getByRole("link", { name: "Account activity", exact: true })).toHaveCount(0);
    } finally {
      await restricted.close();
    }
  } finally {
    await context.close();
  }
});
