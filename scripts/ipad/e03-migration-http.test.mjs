import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { mkdir, readFile, rm, writeFile } from "node:fs/promises";
import { join, resolve } from "node:path";
import { test } from "node:test";
import { cleanupFixture, migrationBooksQuery, waitForInitialScan } from "./e03-migration-setup.mjs";
import {
  addMigrationEbooks,
  createAudiobookshelfBackup,
  createBookloreFixture,
  createCalibreSnapshot,
  createMigrationMediaFixtures,
  sourceCfi,
  sourcePrefix,
  startAudiobookshelfFixture,
} from "./e03-migration-fixtures.mjs";

const base = process.env.IPAD_E03_API_URL ?? "http://localhost:16482/api/v1";
assert.ok(["localhost", "127.0.0.1"].includes(new URL(base).hostname), "Migration acceptance requires an isolated local server");
const artifactsRoot = resolve(
  process.env.IPAD_MIGRATION_ARTIFACTS_ROOT ??
    (process.env.IPAD_TEST_ARTIFACTS ? join(process.env.IPAD_TEST_ARTIFACTS, "migration-http") : "test-results/ipad/e03-migration-http"),
);
const booksRoot = process.env.IPAD_MIGRATION_BOOKS_ROOT;
const importRoot = process.env.IPAD_MIGRATION_IMPORT_ROOT;

async function request(path, token, body, method = body ? "POST" : "GET") {
  return fetch(`${base}/${path}`, {
    method,
    signal: AbortSignal.timeout(45_000),
    headers: { ...(token ? { Authorization: `Bearer ${token}` } : {}), ...(body ? { "Content-Type": "application/json" } : {}) },
    body: body ? JSON.stringify(body) : undefined,
  });
}

test(
  "IPAD-E03-A03-batches: 105 scanned books migrate in bounded provider batches and cancelled apply resumes without duplicate reading state",
  { timeout: 240_000 },
  async () => {
    assert.ok(booksRoot && importRoot, "Run the isolated E03 harness and source its e03-runtime.env");
    const owner = await login("ipad-owner");
    const name = `audiobookshelf-batches-${randomUUID()}`;
    const folder = join(booksRoot, name);
    const evidence = join(artifactsRoot, name);
    await mkdir(evidence, { recursive: true });
    let sourceFixture;
    let library;
    let activeRunId;
    try {
      const books = await addMigrationEbooks(folder, await createMigrationMediaFixtures(folder), 105);
      sourceFixture = await startAudiobookshelfFixture(books, { bookmarkCount: 501 });
      const scanned = await scanFixture(books, folder, owner, (created) => {
        library = created;
      });
      const ebook = scanned.targetBooks.find((book) => book.files[0].absolutePath === books[0].path);
      assert.ok(ebook, "Public book file paths must identify the newer-state fixture");
      await json(`books/files/${ebook.files[0].id}/progress`, owner.accessToken, {
        source: "text",
        percentage: 83,
        cfi: "epubcfi(/6/2[chapter]!/4/2/1:11)",
      });
      const source = await json("migration/sources", owner.accessToken, {
        type: "audiobookshelf",
        name: "E03 durable batches",
        connectionConfig: sourceFixture.connectionConfig,
      });
      const pathMappings = [{ sourcePrefix, targetPrefix: folder }];
      const profile = await json("migration/profiles", owner.accessToken, {
        sourceId: source.id,
        name: "E03 durable mapping",
        userMappings: [{ sourceUserId: sourceFixture.sourceUserId, targetUserId: owner.user.id }],
        pathMappings,
      });
      assert.equal(
        (await json(`migration/sources/${source.id}/path-mappings/validate`, owner.accessToken, { pathMappings })).summary.matchedTargetPaths,
        105,
      );
      const plan = await json("migration/plans/dry-run", owner.accessToken, { profileId: profile.id });
      assert.equal(plan.summary.matchedBooks, 105);
      assert.equal(plan.summary.unresolvedBooks, 0);
      const newerNote = await json(`books/${ebook.id}/annotations`, owner.accessToken, {
        cfi: "epubcfi(/6/2[chapter]!/4/2/1:11)",
        text: "Newer cancellation regression passage",
        note: "Keep note through cancellation and retry",
      });
      await json("__faults/migration", owner.accessToken, { mode: "delay", stage: "user_state", delayMs: 20_000 });
      const run = await json("migration/runs/live", owner.accessToken, { planArtifactId: plan.id });
      activeRunId = run.id;
      assert.equal(run.state, "running");
      const held = await eventually(async () => {
        const checkpoint = await json("__faults/migration", owner.accessToken);
        return checkpoint.observed?.runId === run.id && checkpoint.observed.stage === "user_state" ? checkpoint : null;
      }, "genuine user-state checkpoint after metadata commits");
      assert.equal((await json(`books/${ebook.id}`, owner.accessToken)).title, `Imported ${books[0].title}`);
      const cancelled = await json(`migration/runs/${run.id}/cancel`, owner.accessToken, {});
      assert.equal(cancelled.state, "failed");
      assert.equal(cancelled.currentStage, "cancelled");
      await json("__faults/migration", owner.accessToken, { mode: "none" });
      for (let check = 0; check < 10; check++) {
        const released = await json(`migration/runs/${run.id}/progress`, owner.accessToken);
        assert.equal(released.run.state, "failed");
        assert.equal(released.run.currentStage, "cancelled", "Accepted cancellation must survive checkpoint release");
        await new Promise((resolve) => setTimeout(resolve, 100));
      }
      const interrupted = await json(`migration/runs/${run.id}/progress`, owner.accessToken);
      await writeFile(join(evidence, "interrupted-progress.json"), JSON.stringify(interrupted, null, 2));
      const retried = await json(`migration/runs/${run.id}/retry`, owner.accessToken, {});
      assert.equal(retried.id, run.id);
      const completed = await eventually(
        async () => {
          const value = await json(`migration/runs/${run.id}/progress`, owner.accessToken);
          if (value.run.state === "failed") assert.fail(`Resumed migration failed: ${value.run.errorMessage}`);
          return value.run.state === "completed" ? value : null;
        },
        "durable batch retry completion",
        120_000,
      );
      assert.equal(completed.totals.failed, 0);
      const metadataMetric = completed.metrics.find((metric) => metric.entityType === "book_metadata");
      assert.ok(metadataMetric, "Migration reports must expose imported metadata outcomes");
      assert.equal(metadataMetric.processed, 105);
      assert.equal(metadataMetric.imported, 105);
      const bookmarkMetric = completed.metrics.find((metric) => metric.entityType === "bookmarks");
      assert.equal(bookmarkMetric?.processed, 501);
      assert.equal(bookmarkMetric?.imported, 501);
      assert.equal((await listBooks(library.id, owner.accessToken)).total, 105);
      for (const target of scanned.targetBooks) assert.equal((await json(`books/${target.id}`, owner.accessToken)).readStatus.status, "reading");
      const afterProgress = await json(`books/files/${ebook.files[0].id}/progress`, owner.accessToken);
      assert.equal(afterProgress.percentage, 83);
      const audio = scanned.targetBooks.find((book) => book.files[0].format === "mp3");
      const bookmarks = await json(`books/${audio.id}/bookmarks`, owner.accessToken);
      assert.equal(bookmarks.length, 501);
      assert.equal(new Set(bookmarks.map((bookmark) => bookmark.id)).size, 501);
      const notesAfterRetry = await json(`books/${ebook.id}/annotations?page=1&pageSize=100`, owner.accessToken);
      assert.equal(notesAfterRetry.items.filter((note) => note.id === newerNote.id && note.note === newerNote.note).length, 1);
      await json("__faults/migration", owner.accessToken, { mode: "delay", stage: "completed", delayMs: 20_000 });
      const finalRun = await json("migration/runs/live", owner.accessToken, { planArtifactId: plan.id });
      activeRunId = finalRun.id;
      await eventually(
        async () => (await json("__faults/migration", owner.accessToken)).observed?.runId === finalRun.id,
        "near-completion checkpoint after all import commits",
      );
      const [cancelAtCompletion] = await Promise.all([
        request(`migration/runs/${finalRun.id}/cancel`, owner.accessToken, {}),
        json("__faults/migration", owner.accessToken, { mode: "none" }),
      ]);
      const finalProgress = await eventually(async () => {
        const value = await json(`migration/runs/${finalRun.id}/progress`, owner.accessToken);
        return value.run.state !== "running" ? value : null;
      }, "near-completion cancellation outcome");
      if (cancelAtCompletion.ok) {
        assert.equal((await cancelAtCompletion.json()).currentStage, "cancelled");
        assert.equal(finalProgress.run.state, "failed");
        assert.equal(finalProgress.run.currentStage, "cancelled");
      } else {
        assert.ok(cancelAtCompletion.status >= 400 && cancelAtCompletion.status < 500);
        assert.equal(finalProgress.run.state, "completed");
      }
      await new Promise((resolve) => setTimeout(resolve, 300));
      assert.deepEqual((await json(`migration/runs/${finalRun.id}/progress`, owner.accessToken)).run, finalProgress.run);
      assert.equal((await listBooks(library.id, owner.accessToken)).total, 105);
      assert.deepEqual(await json(`books/${audio.id}/bookmarks`, owner.accessToken), bookmarks);
      assert.deepEqual(await json(`books/${ebook.id}/annotations?page=1&pageSize=100`, owner.accessToken), notesAfterRetry);
      const requests = sourceFixture.requests.filter((row) => row.path === "/api/items/batch/get");
      assert.ok(requests.some((row) => row.batchSize === 100));
      assert.ok(requests.some((row) => row.batchSize === 5));
      assert.ok(requests.every((row) => row.batchSize <= 100));
      const publicReport = await json(`migration/runs/${run.id}/report`, owner.accessToken);
      assert.equal(publicReport.details.matchedBooks.length, 40);
      assert.equal(publicReport.detailsPagination.matchedBooks.total, 105);
      assert.equal(publicReport.detailsPagination.matchedBooks.nextOffset, 40);
      const matchedBooks = await reportDetails(run.id, "matched", 105, owner.accessToken);
      const reportResponse = await request(`migration/runs/${run.id}/report/export?format=json`, owner.accessToken);
      assert.equal(reportResponse.status, 200);
      const reportBytes = Buffer.from(await reportResponse.arrayBuffer());
      const report = JSON.parse(reportBytes.toString("utf8"));
      assert.equal(report.details.matchedBooks.length, 105);
      assert.equal(new Set(report.details.matchedBooks.map((book) => book.targetBookId)).size, 105);
      assert.deepEqual(report.details.matchedBooks, matchedBooks);
      await writeFile(join(evidence, "report.json"), reportBytes);
      await writeFile(join(evidence, "source-requests.json"), JSON.stringify(sourceFixture.requests, null, 2));
      await writeFile(
        join(evidence, "evidence.json"),
        JSON.stringify(
          {
            testId: "IPAD-E03-A03-batches",
            libraryId: library.id,
            runId: run.id,
            scannedBooks: 105,
            heldCheckpoint: held.observed,
            cancelledState: cancelled.state,
            nearCompletionCancelStatus: cancelAtCompletion.status,
            nearCompletionRun: finalProgress.run,
            retriedSameRun: true,
            processedMetadata: metadataMetric.processed,
            importedMetadata: metadataMetric.imported,
            newerProgress: 83,
            maxProviderBatchSize: 100,
          },
          null,
          2,
        ),
      );
    } finally {
      await cleanupFixture([
        () => request("__faults/migration", owner.accessToken, { mode: "none" }),
        async () => {
          if (!activeRunId) return;
          const response = await request(`migration/runs/${activeRunId}/progress`, owner.accessToken);
          if (response.ok && (await response.json()).run.state === "running")
            await request(`migration/runs/${activeRunId}/cancel`, owner.accessToken, {});
        },
        () => sourceFixture?.close(),
        async () => {
          if (library) assert.equal((await request(`libraries/${library.id}`, owner.accessToken, undefined, "DELETE")).status, 204);
        },
        () => rm(folder, { recursive: true, force: true }),
        () => request("auth/logout", undefined, { refreshToken: owner.refreshToken }),
      ]);
    }
  },
);

async function json(path, token, body, method) {
  const response = await request(path, token, body, method);
  assert.ok(response.ok, `${path}: ${response.status} ${await response.clone().text()}`);
  return response.json();
}

async function reportDetails(runId, kind, expectedTotal, token) {
  const items = [];
  let offset = 0;
  while (true) {
    const page = await json(`migration/runs/${runId}/report/details?kind=${kind}&offset=${offset}&limit=40`, token);
    assert.equal(page.runId, runId);
    assert.equal(page.kind, kind);
    assert.equal(page.offset, offset);
    assert.equal(page.total, expectedTotal);
    assert.ok(page.items.length <= 40);
    items.push(...page.items);
    if (page.nextOffset === null) break;
    assert.ok(page.nextOffset > offset);
    offset = page.nextOffset;
  }
  assert.equal(items.length, expectedTotal);
  return items;
}

async function login(username) {
  return json("auth/login", undefined, {
    username,
    password: process.env.IPAD_FIXTURE_PASSWORD ?? "IpadFixture123",
    clientKind: "native",
    deviceLabel: "E03 migration public HTTP",
  });
}

async function eventually(operation, description, timeout = 60_000) {
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) {
    const value = await operation();
    if (value) return value;
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  assert.fail(`Timed out awaiting ${description}`);
}

async function listBooks(libraryId, token) {
  const items = [];
  let page = 0;
  while (true) {
    const result = await json(`libraries/${libraryId}/books`, token, migrationBooksQuery(page));
    items.push(...result.items);
    if (items.length >= result.total) return { items, total: result.total };
    assert.ok(result.items.length, "Library pagination stopped before total");
    page++;
    assert.ok(page < 20, "Fixture pagination exceeded its bounded 1,900-book budget");
  }
}

async function scanFixture(books, folder, owner, onCreated) {
  const library = await json("libraries", owner.accessToken, {
    name: `E03 migration ${randomUUID()}`,
    icon: "Library",
    folders: [folder],
    watch: false,
    organizationMode: "book_per_folder",
    fileWriteEnabled: false,
  });
  onCreated(library);
  await waitForInitialScan(library.id, (path) => json(path, owner.accessToken));
  const listed = await listBooks(library.id, owner.accessToken);
  assert.equal(listed.total, books.length);
  const targetBooks = await Promise.all(listed.items.map((book) => json(`books/${book.id}`, owner.accessToken)));
  return { library, targetBooks };
}

test("IPAD-E03-A03-access: a settings admin manages their own setup and maps only their own reading data", { timeout: 60_000 }, async () => {
  assert.ok(booksRoot && importRoot, "Run the isolated E03 harness and source its e03-runtime.env");
  const admin = await login("ipad-settings-admin");
  const superuser = await login("ipad-owner");
  const folder = join(booksRoot, `migration-access-${randomUUID()}`);
  let external;
  let source;
  try {
    assert.equal(admin.user.isSuperuser, false);
    const books = await createMigrationMediaFixtures(folder);
    external = await startAudiobookshelfFixture(books);
    source = await json("migration/sources", admin.accessToken, {
      type: "audiobookshelf",
      name: "E03 own migration setup",
      connectionConfig: external.connectionConfig,
    });
    const targets = await json("migration/target-users", admin.accessToken);
    assert.deepEqual(
      targets.map((target) => target.id),
      [admin.user.id],
    );
    assert.equal(
      (
        await request("migration/profiles", admin.accessToken, {
          sourceId: source.id,
          name: "Denied foreign reading data",
          userMappings: [{ sourceUserId: external.sourceUserId, targetUserId: superuser.user.id }],
        })
      ).status,
      403,
    );
    const profile = await json("migration/profiles", admin.accessToken, {
      sourceId: source.id,
      name: "E03 own reading data",
      userMappings: [{ sourceUserId: external.sourceUserId, targetUserId: admin.user.id }],
    });
    assert.deepEqual(profile.userMappings, [{ sourceUserId: external.sourceUserId, targetUserId: admin.user.id }]);
    const state = await json("migration/state", admin.accessToken);
    assert.equal(state.active.source.id, source.id);
    assert.equal(state.active.profile.id, profile.id);
    assert.equal((await json(`migration/sources/${source.id}/validate`, superuser.accessToken, {})).ok, true);
    assert.equal((await request(`migration/sources/${source.id}`, admin.accessToken, undefined, "DELETE")).status, 204);
    assert.equal((await json("migration/state", admin.accessToken)).active, null);
    source = undefined;
  } finally {
    if (source) await request(`migration/sources/${source.id}`, admin.accessToken, undefined, "DELETE");
    await external?.close();
    await rm(folder, { recursive: true, force: true });
    for (const session of [admin, superuser]) await request("auth/logout", undefined, { refreshToken: session.refreshToken });
  }
});

const providers = [
  {
    id: "booklore",
    type: "booklore",
    create: (root, books) => createBookloreFixture(books, `e03_booklore_${process.pid}_${Date.now()}`),
    annotations: true,
  },
  {
    id: "grimmory",
    type: "grimmory",
    create: (root, books) => createBookloreFixture(books, `e03_grimmory_${process.pid}_${Date.now()}`),
    annotations: true,
  },
  { id: "audiobookshelf-api", type: "audiobookshelf", create: (root, books) => startAudiobookshelfFixture(books) },
  { id: "audiobookshelf-backup", type: "audiobookshelf", create: createAudiobookshelfBackup },
  { id: "calibre-web-automated", type: "calibre_web_automated", create: createCalibreSnapshot },
];

for (const provider of providers) {
  test(
    `IPAD-E03-A03-${provider.id}: configure, map, dry-run, apply and retry preserve readable artifacts and newer private state`,
    { timeout: 180_000 },
    async () => {
      assert.ok(
        booksRoot && importRoot,
        "Run the isolated E03 harness and source its e03-runtime.env (IPAD_MIGRATION_BOOKS_ROOT and IPAD_MIGRATION_IMPORT_ROOT required)",
      );
      const owner = await login("ipad-owner");
      const restricted = await login("ipad-restricted");
      const otherAdmin = await login("ipad-settings-admin");
      const scenarioName = `${provider.id}-${randomUUID()}`;
      const folder = join(booksRoot, scenarioName);
      const sourceFolder = join(importRoot, scenarioName);
      const evidence = join(artifactsRoot, scenarioName);
      await mkdir(evidence, { recursive: true });
      let external;
      let library;
      let activeRunId;
      try {
        const books = await createMigrationMediaFixtures(folder);
        const representativeBooks = books.slice(0, 4);
        const originalBytes = new Map(await Promise.all(representativeBooks.map(async (book) => [book.format, await readFile(book.path)])));
        external = await provider.create(sourceFolder, books);
        const scanned = await scanFixture(books, folder, owner, (created) => {
          library = created;
        });
        const targetByPath = new Map(scanned.targetBooks.map((book) => [book.files[0].absolutePath, book]));
        const representativePaths = new Set(representativeBooks.map((book) => book.path));
        const targetByFormat = new Map(
          scanned.targetBooks.filter((book) => representativePaths.has(book.files[0].absolutePath)).map((book) => [book.files[0].format, book]),
        );
        assert.equal(targetByFormat.size, 4);
        const ebook = targetByFormat.get("epub");
        assert.ok(ebook);
        await json(`books/files/${ebook.files[0].id}/progress`, owner.accessToken, {
          source: "text",
          percentage: 77,
          cfi: "epubcfi(/6/2[chapter]!/4/2/1:9)",
        });
        await json(`books/${ebook.id}/status`, owner.accessToken, { status: "on_hold" }, "PATCH");
        const newer = await json(`books/${ebook.id}/annotations`, owner.accessToken, {
          cfi: "epubcfi(/6/2[chapter]!/4/2/1:9)",
          text: "Newer private passage",
          note: "Keep newer private note",
        });
        const journalId = randomUUID();
        await json(`books/${ebook.id}/journal`, owner.accessToken, {
          clientId: journalId,
          body: "Existing reader journal survives migration",
          cfi: sourceCfi,
        });
        const before = await json(`books/${ebook.id}`, owner.accessToken);
        const beforeProgress = await json(`books/files/${ebook.files[0].id}/progress`, owner.accessToken);
        assert.equal(
          (
            await request("migration/sources", restricted.accessToken, {
              type: provider.type,
              name: "Denied fixture",
              connectionConfig: external.connectionConfig,
            })
          ).status,
          403,
        );
        assert.equal((await request("migration/supported-types")).status, 401);
        const source = await json("migration/sources", owner.accessToken, {
          type: provider.type,
          name: `E03 ${provider.id}`,
          connectionConfig: external.connectionConfig,
        });
        assert.equal(source.capabilities.ok, true);
        assert.equal((await request(`migration/sources/${source.id}/user-mapping-suggestions`, otherAdmin.accessToken)).status, 403);
        assert.equal((await request(`migration/sources/${source.id}/validate`, otherAdmin.accessToken, {})).status, 403);
        assert.equal((await json("migration/state", otherAdmin.accessToken)).active, null);
        assert.ok(!JSON.stringify(source.connectionConfig).includes("E03SourceFixture"));
        assert.ok(!JSON.stringify(source.connectionConfig).includes("E03-provider-fixture-token"));
        const suggestions = await json(`migration/sources/${source.id}/user-mapping-suggestions`, owner.accessToken);
        assert.ok(suggestions.suggestions.some((row) => row.sourceUserId === external.sourceUserId));
        const pathMappings = [{ sourcePrefix, targetPrefix: folder }];
        const profile = await json("migration/profiles", owner.accessToken, {
          sourceId: source.id,
          name: "E03 public migration mappings",
          userMappings: [{ sourceUserId: external.sourceUserId, targetUserId: owner.user.id }],
          pathMappings,
        });
        assert.equal((await request("migration/plans/dry-run", otherAdmin.accessToken, { profileId: profile.id })).status, 403);
        const validation = await json(`migration/sources/${source.id}/path-mappings/validate`, owner.accessToken, { pathMappings, sampleLimit: 5 });
        assert.equal(validation.summary.matchedTargetPaths, 4);
        const plan = await json("migration/plans/dry-run", owner.accessToken, { profileId: profile.id });
        assert.equal(plan.summary.matchedBooks, 4);
        assert.equal(plan.summary.unresolvedBooks, 0);
        assert.equal(plan.summary.duplicateBookMatches, 0);
        assert.equal(plan.summary.mappedUsers, 1);
        assert.deepEqual(await json(`books/${ebook.id}`, owner.accessToken), before);
        assert.deepEqual(await json(`books/files/${ebook.files[0].id}/progress`, owner.accessToken), beforeProgress);
        await writeFile(join(evidence, "dry-run.json"), JSON.stringify(plan, null, 2));
        assert.equal((await request("migration/runs/live", owner.accessToken, { planArtifactId: plan.id, unsupported: true })).status, 400);
        const run = await json("migration/runs/live", owner.accessToken, { planArtifactId: plan.id });
        activeRunId = run.id;
        const progress = await eventually(async () => {
          const value = await json(`migration/runs/${run.id}/progress`, owner.accessToken);
          if (value.run.state === "failed") assert.fail(`Migration failed: ${value.run.errorMessage}`);
          return value.run.state === "completed" ? value : null;
        }, "migration apply completion");
        assert.equal(progress.totals.failed, 0);
        assert.ok(progress.totals.imported >= 4);
        const report = await json(`migration/runs/${run.id}/report`, owner.accessToken);
        assert.equal((await request(`migration/runs/${run.id}/report/export?format=json`, otherAdmin.accessToken)).status, 403);
        assert.equal((await request(`migration/runs/${run.id}/retry`, otherAdmin.accessToken, {})).status, 403);
        assert.equal(report.details.matchedBooks.length, 4);
        assert.equal(report.detailsPagination.matchedBooks.total, 4);
        assert.equal(report.detailsPagination.matchedBooks.nextOffset, null);
        const matchedBooks = await reportDetails(run.id, "matched", 4, owner.accessToken);
        assert.equal(new Set(matchedBooks.map((row) => row.targetBookId)).size, 4);
        assert.ok(matchedBooks.every((row) => row.strategy === "file_path"));
        for (const book of books) {
          const sourceId = provider.type === "audiobookshelf" ? `book-${book.id}` : String(book.id);
          assert.equal(matchedBooks.find((match) => match.sourceBookId === sourceId)?.targetBookId, targetByPath.get(book.path).id);
        }
        assert.equal((await listBooks(library.id, owner.accessToken)).total, 4);
        for (const book of representativeBooks) {
          const target = targetByFormat.get(book.format);
          const detail = await json(`books/${target.id}`, owner.accessToken);
          assert.equal(detail.title, `Imported ${book.title}`);
          let deliveryPath = `books/files/${target.files[0].id}/serve`;
          if (book.format === "mp3") {
            const manifest = await json(`audiobooks/${target.id}/manifest`, owner.accessToken);
            assert.equal(manifest.assets.length, 1);
            deliveryPath = `audiobooks/${target.id}/assets/${manifest.assets[0].assetId}/content`;
          }
          const served = await request(deliveryPath, owner.accessToken);
          assert.equal(served.status, 200);
          const actual = Buffer.from(await served.arrayBuffer());
          assert.deepEqual(actual, originalBytes.get(book.format), `${book.format} delivery changed the real scanned artifact`);
          await writeFile(join(evidence, `delivered.${book.format}`), actual);
        }
        const savedProgress = await json(`books/files/${ebook.files[0].id}/progress`, owner.accessToken);
        assert.equal(savedProgress.percentage, 77);
        assert.equal(savedProgress.cfi, beforeProgress.cfi);
        assert.equal((await json(`books/${ebook.id}`, owner.accessToken)).readStatus.status, "on_hold");
        const notes = await json(`books/${ebook.id}/annotations?page=1&pageSize=100`, owner.accessToken);
        assert.ok(notes.items.some((note) => note.id === newer.id && note.note === "Keep newer private note"));
        if (provider.annotations) assert.equal(notes.items.filter((note) => note.note === "Imported permitted passage note").length, 1);
        const journal = await json(`books/${ebook.id}/journal`, owner.accessToken);
        assert.ok(journal.some((entry) => entry.clientId === journalId && entry.body === "Existing reader journal survives migration"));
        const audio = targetByFormat.get("mp3");
        assert.equal((await json(`books/${audio.id}/audio-progress`, owner.accessToken)).positionSeconds, 4);
        const exported = await request(`migration/runs/${run.id}/report/export?format=json`, owner.accessToken);
        assert.equal(exported.status, 200);
        assert.match(exported.headers.get("content-disposition"), new RegExp(`migration-run-${run.id}-report.json`));
        const reportBytes = Buffer.from(await exported.arrayBuffer());
        const exportedReport = JSON.parse(reportBytes.toString("utf8"));
        assert.deepEqual(exportedReport.run, report.run);
        assert.deepEqual(exportedReport.totals, report.totals);
        assert.deepEqual(exportedReport.metrics, report.metrics);
        assert.deepEqual(exportedReport.details.matchedBooks, matchedBooks);
        await writeFile(join(evidence, "report.json"), reportBytes);
        const csv = await request(`migration/runs/${run.id}/report/export?format=csv`, owner.accessToken);
        assert.equal(csv.status, 200);
        const csvBytes = Buffer.from(await csv.arrayBuffer());
        const csvText = csvBytes.toString("utf8");
        assert.match(csvText, /^section,stage,entityType,processed,imported,skipped,unresolved,failed,/);
        assert.equal(csvText.split("\n").filter((line) => line.startsWith("matched_books,")).length, 4);
        for (const target of targetByFormat.values()) assert.ok(csvText.includes(String(target.id)));
        await writeFile(join(evidence, "report.csv"), csvBytes);
        const secondRun = await json("migration/runs/live", owner.accessToken, { planArtifactId: plan.id });
        activeRunId = secondRun.id;
        await eventually(async () => {
          const value = await json(`migration/runs/${secondRun.id}/progress`, owner.accessToken);
          if (value.run.state === "failed") assert.fail(value.run.errorMessage);
          return value.run.state === "completed";
        }, "idempotent repeated apply");
        assert.equal((await listBooks(library.id, owner.accessToken)).total, 4);
        assert.deepEqual(await json(`books/${ebook.id}/annotations?page=1&pageSize=100`, owner.accessToken), notes);
        assert.equal((await json(`books/files/${ebook.files[0].id}/progress`, owner.accessToken)).percentage, 77);
        assert.equal((await request(`migration/runs/${secondRun.id}/report`, restricted.accessToken)).status, 403);
        if (external.requests) {
          assert.ok(external.requests.filter((row) => row.batchSize).every((row) => row.batchSize <= 100));
          await writeFile(join(evidence, "source-requests.json"), JSON.stringify(external.requests, null, 2));
        }
        await writeFile(
          join(evidence, "evidence.json"),
          JSON.stringify(
            {
              testId: `IPAD-E03-A03-${provider.id}`,
              publicApi: base,
              libraryId: library.id,
              runId: run.id,
              retryRunId: secondRun.id,
              formats: representativeBooks.map((book) => book.format),
              matchedBooks: 4,
              exactArtifactBytes: true,
              newerProgress: 77,
              preservedPrivateNoteId: newer.id,
            },
            null,
            2,
          ),
        );
      } finally {
        await cleanupFixture([
          async () => {
            if (!activeRunId) return;
            const response = await request(`migration/runs/${activeRunId}/progress`, owner.accessToken);
            if (response.ok && (await response.json()).run.state === "running")
              await request(`migration/runs/${activeRunId}/cancel`, owner.accessToken, {});
          },
          () => external?.close(),
          async () => {
            if (library) assert.equal((await request(`libraries/${library.id}`, owner.accessToken, undefined, "DELETE")).status, 204);
          },
          () => rm(folder, { recursive: true, force: true }),
          () => rm(sourceFolder, { recursive: true, force: true }),
          ...[owner, restricted, otherAdmin].map((session) => () => request("auth/logout", undefined, { refreshToken: session.refreshToken })),
        ]);
      }
    },
  );
}
