import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { mkdir, readFile, rm, writeFile } from "node:fs/promises";
import { basename, join, resolve } from "node:path";
import { cleanupFixture, migrationBooksQuery, waitForInitialScan, writeFixtureCheckpoint } from "./e03-migration-setup.mjs";
import {
  createAudiobookshelfBackup,
  addMigrationEbooks,
  createBookloreFixture,
  createCalibreSnapshot,
  createMigrationMediaFixtures,
  removeBookloreFixture,
  sourcePrefix,
  startAudiobookshelfFixture,
} from "./e03-migration-fixtures.mjs";

const base = process.env.IPAD_E03_API_URL ?? "http://localhost:16482/api/v1";
assert.ok(["localhost", "127.0.0.1"].includes(new URL(base).hostname), "Native migration fixtures require an isolated local server");
const booksRoot = process.env.IPAD_MIGRATION_BOOKS_ROOT;
const importRoot = process.env.IPAD_MIGRATION_IMPORT_ROOT;
assert.ok(booksRoot && importRoot, "Source the retained E03 harness e03-runtime.env first");
const artifactRoot = resolve(
  process.env.IPAD_MIGRATION_ARTIFACTS_ROOT ??
    (process.env.IPAD_TEST_ARTIFACTS ? join(process.env.IPAD_TEST_ARTIFACTS, "migration-native") : "test-results/ipad/e03-migration-native-fixtures"),
);
await mkdir(artifactRoot, { recursive: true });
const checkpointPath = join(artifactRoot, "fixture-checkpoint.json");
let checkpoint;
try {
  checkpoint = JSON.parse(await readFile(checkpointPath, "utf8"));
} catch (error) {
  if (error.code !== "ENOENT") throw error;
  checkpoint = { version: 1, base, booksRoot: resolve(booksRoot), importRoot: resolve(importRoot), status: "setting-up", fixtures: [] };
}
assert.equal(checkpoint.version, 1);
assert.equal(checkpoint.base, base, "Resume requires the same isolated API");
assert.equal(checkpoint.booksRoot, resolve(booksRoot));
assert.equal(checkpoint.importRoot, resolve(importRoot));
assert.notEqual(checkpoint.status, "cleaned", "Choose a fresh artifact directory after explicit cleanup");
const save = async () => {
  checkpoint.updatedAt = new Date().toISOString();
  await writeFixtureCheckpoint(checkpointPath, checkpoint);
};
await save();
async function request(path, token, body, method = body ? "POST" : "GET") {
  const response = await fetch(`${base}/${path}`, {
    method,
    signal: AbortSignal.timeout(45_000),
    headers: { ...(token ? { Authorization: `Bearer ${token}` } : {}), ...(body ? { "Content-Type": "application/json" } : {}) },
    body: body ? JSON.stringify(body) : undefined,
  });
  const responseText = await response.text();
  assert.ok(response.ok, `${path}: ${response.status} ${responseText}`);
  return responseText.trim() ? JSON.parse(responseText) : null;
}
const owner = await request("auth/login", undefined, {
  username: "ipad-owner",
  password: process.env.IPAD_FIXTURE_PASSWORD ?? "IpadFixture123",
  clientKind: "native",
  deviceLabel: "E03 native migration fixture setup",
});
const token = owner.accessToken;
const liveSources = new Map();
function verifyOwnedPaths(fixture) {
  assert.match(fixture.name, /^native-[a-z-]+-[0-9a-f-]{36}$/);
  assert.equal(fixture.name.slice(0, -37), `native-${fixture.providerId}`);
  assert.equal(fixture.folder, join(resolve(booksRoot), fixture.name));
  assert.equal(fixture.sourceFolder, join(resolve(importRoot), fixture.name));
  assert.equal(basename(fixture.folder), fixture.name);
  assert.equal(fixture.libraryName, `E03 ${fixture.providerId} native migration ${fixture.name.slice(-36)}`);
  assert.equal(fixture.databaseName, `e03_native_${fixture.providerId}_${fixture.name.slice(-36).replaceAll("-", "")}`);
}
async function verifyOwnedLibrary(fixture) {
  verifyOwnedPaths(fixture);
  const library = await request(`libraries/${fixture.library.id}`, token);
  assert.equal(library.name, fixture.libraryName, "Only the exact checkpoint-owned library may be reused or removed");
  assert.deepEqual(
    library.folders.map((folder) => folder.path),
    [fixture.folder],
  );
}
try {
  if (process.argv.includes("--cleanup")) {
    assert.ok(["ready", "cleaning"].includes(checkpoint.status), "Finish or resume fixture setup before explicit cleanup");
    checkpoint.status = "cleaning";
    await save();
    for (const fixture of [...checkpoint.fixtures].reverse()) {
      verifyOwnedPaths(fixture);
      if (!fixture.libraryDeleted) {
        await verifyOwnedLibrary(fixture);
        const { progress } = await request(`scanner/libraries/${fixture.library.id}/scan-status`, token);
        assert.notEqual(progress?.status, "running", "Never remove fixture files while their scan is running");
        await request(`libraries/${fixture.library.id}`, token, undefined, "DELETE");
        fixture.libraryDeleted = true;
        await save();
      }
      if (["booklore", "grimmory"].includes(fixture.providerId)) {
        assert.equal(fixture.external.connectionConfig.database, fixture.databaseName);
        await removeBookloreFixture(fixture.external.connectionConfig);
      }
      await rm(fixture.folder, { recursive: true, force: true });
      await rm(fixture.sourceFolder, { recursive: true, force: true });
    }
    await rm(join(artifactRoot, "native-config.json"), { force: true });
    await rm(join(artifactRoot, "native-fixtures.env"), { force: true });
    checkpoint.status = "cleaned";
    await save();
    console.log(JSON.stringify({ cleaned: true, checkpointPath }));
  } else {
    assert.notEqual(checkpoint.status, "cleaning", "Complete explicit cleanup before setting up another fixture");
    for (const provider of [
      { id: "booklore", type: "booklore", create: (root, books, fixture) => createBookloreFixture(books, fixture.databaseName) },
      { id: "grimmory", type: "grimmory", create: (root, books, fixture) => createBookloreFixture(books, fixture.databaseName) },
      {
        id: "audiobookshelf-api",
        type: "audiobookshelf",
        create: (root, books, fixture) =>
          startAudiobookshelfFixture(books, {
            bookmarkCount: 501,
            port: fixture.external ? Number(new URL(fixture.external.connectionConfig.baseUrl).port) : 0,
          }),
      },
      { id: "audiobookshelf-backup", type: "audiobookshelf", create: createAudiobookshelfBackup },
      { id: "calibre-web-automated", type: "calibre_web_automated", create: createCalibreSnapshot },
    ]) {
      let fixture = checkpoint.fixtures.find((entry) => entry.providerId === provider.id);
      if (!fixture) {
        const name = `native-${provider.id}-${randomUUID()}`;
        fixture = {
          providerId: provider.id,
          name,
          folder: join(resolve(booksRoot), name),
          sourceFolder: join(resolve(importRoot), name),
          libraryName: `E03 ${provider.id} native migration ${name.slice(-36)}`,
          databaseName: `e03_native_${provider.id}_${name.slice(-36).replaceAll("-", "")}`,
        };
        checkpoint.fixtures.push(fixture);
        await save();
      }
      const { folder, sourceFolder } = fixture;
      if (!fixture.books) {
        const books = await createMigrationMediaFixtures(folder);
        for (const book of books) book.title = `${provider.id} ${book.title}`;
        if (provider.id === "audiobookshelf-api") await addMigrationEbooks(folder, books, 105);
        fixture.books = books;
        await save();
      }
      const books = fixture.books;
      if (!fixture.external || provider.id === "audiobookshelf-api") {
        const external = await provider.create(sourceFolder, books, fixture);
        liveSources.set(provider.id, external);
        fixture.external = { connectionConfig: external.connectionConfig, sourceUserId: external.sourceUserId, control: external.control };
        if (fixture.config) Object.assign(fixture.config, { connectionConfig: external.connectionConfig, control: external.control });
        await save();
      }
      if (!fixture.library) {
        fixture.library = await request("libraries", token, {
          name: fixture.libraryName,
          icon: "Library",
          folders: [folder],
          watch: false,
          organizationMode: "book_per_folder",
          fileWriteEnabled: false,
          metadataPrecedence: ["embedded"],
        });
        await save();
      }
      await verifyOwnedLibrary(fixture);
      if (fixture.config) continue;
      const metadataConfig = await request(
        `book-metadata-fetch/config/libraries/${fixture.library.id}`,
        token,
        { enabled: false, triggerOnImport: false },
        "PUT",
      );
      assert.equal(metadataConfig.enabled, false);
      assert.equal(metadataConfig.triggerOnImport, false);
      fixture.scanHistory = await waitForInitialScan(fixture.library.id, (path) => request(path, token), {
        onProgress: async (observation) => {
          fixture.scanObservation = observation;
          await save();
          console.log(JSON.stringify({ provider: provider.id, phase: "initial-scan", ...observation }));
        },
      });
      await save();
      const listed = await request(`libraries/${fixture.library.id}/books`, token, migrationBooksQuery());
      assert.equal(listed.total, provider.id === "audiobookshelf-api" ? 105 : 4);
      const expectedBooks = [];
      const remaining = new Map(books.slice(0, 4).map((book) => [book.path, book]));
      const bookIds = [];
      for (let page = 0; page < Math.ceil(listed.total / 100); page++) {
        const result = page === 0 ? listed : await request(`libraries/${fixture.library.id}/books`, token, migrationBooksQuery(page));
        for (const listedBook of result.items) {
          bookIds.push(listedBook.id);
          if (remaining.size === 0) continue;
          const detail = await request(`books/${listedBook.id}`, token);
          for (const file of detail.files) {
            const media = remaining.get(file.absolutePath);
            if (!media) continue;
            expectedBooks.push({ id: detail.id, fileId: file.id, format: media.format, title: `Imported ${media.title}`, path: media.path });
            remaining.delete(media.path);
          }
        }
      }
      assert.equal(remaining.size, 0, "All four public media scan outcomes must be available");
      expectedBooks.sort((left, right) => ["epub", "pdf", "cbz", "mp3"].indexOf(left.format) - ["epub", "pdf", "cbz", "mp3"].indexOf(right.format));
      const ebook = expectedBooks.find((book) => book.format === "epub");
      if (!fixture.privateNote) {
        await request(`books/files/${ebook.fileId}/progress`, token, { source: "text", percentage: 77, cfi: "epubcfi(/6/2[chapter]!/4/2/1:9)" });
        await request(`books/${ebook.id}/status`, token, { status: "on_hold" }, "PATCH");
        const existing = await request(`books/${ebook.id}/annotations?page=1&pageSize=100`, token);
        fixture.privateNote =
          existing.items.find((note) => note.note === `Keep newer ${provider.id} private note`) ??
          (await request(`books/${ebook.id}/annotations`, token, {
            cfi: "epubcfi(/6/2[chapter]!/4/2/1:9)",
            text: "Newer private passage",
            note: `Keep newer ${provider.id} private note`,
          }));
        await save();
      }
      const privateNote = fixture.privateNote;
      fixture.config = {
        type: provider.type,
        mode: fixture.external.connectionConfig.mode ?? "database",
        name: `E03 ${provider.id}`,
        connectionConfig: fixture.external.connectionConfig,
        sourceUserId: fixture.external.sourceUserId,
        targetUsername: "ipad-owner",
        sourcePrefix,
        targetPrefix: folder,
        expectedTitle: `Imported ${books[0].title}`,
        expectedBooks,
        expectedTotal: listed.total,
        expectedAudioBookmarks: provider.id === "audiobookshelf-api" ? 501 : 1,
        privateNoteId: privateNote.id,
        privateNote: privateNote.note,
        importsPassageNote: ["booklore", "grimmory"].includes(provider.id),
        control: fixture.external.control,
        libraryId: fixture.library.id,
        bookIds,
      };
      await save();
    }
    if (process.argv.includes("--apply")) {
      for (const fixture of checkpoint.fixtures) {
        if (fixture.appliedRunId) continue;
        const config = fixture.config;
        const source = await request("migration/sources", token, {
          type: config.type,
          name: `${config.name} browser preparation`,
          connectionConfig: config.connectionConfig,
        });
        const profile = await request("migration/profiles", token, {
          sourceId: source.id,
          name: `${config.name} browser preparation`,
          userMappings: [{ sourceUserId: config.sourceUserId, targetUserId: owner.user.id }],
          pathMappings: [{ sourcePrefix: config.sourcePrefix, targetPrefix: config.targetPrefix }],
        });
        const plan = await request("migration/plans/dry-run", token, { profileId: profile.id });
        assert.equal(plan.summary.matchedBooks, config.expectedTotal);
        const run = await request("migration/runs/live", token, { planArtifactId: plan.id });
        const deadline = Date.now() + 180_000;
        let completed = false;
        while (Date.now() < deadline) {
          const progress = await request(`migration/runs/${run.id}/progress`, token);
          assert.notEqual(progress.run.state, "failed", progress.run.errorMessage);
          if (progress.run.state === "completed") {
            assert.equal(progress.totals.failed, 0);
            completed = true;
            break;
          }
          await new Promise((resolve) => setTimeout(resolve, 1_000));
        }
        assert.ok(completed, `Browser preparation migration ${run.id} did not complete`);
        fixture.appliedRunId = run.id;
        await save();
      }
    }
    const configs = checkpoint.fixtures.map((fixture) => fixture.config);
    assert.equal(configs.length, 5);
    assert.ok(configs.every(Boolean));
    await writeFile(join(artifactRoot, "native-config.json"), JSON.stringify(configs, null, 2), { mode: 0o600 });
    const quoted = `'${JSON.stringify(configs).replaceAll("'", "'\\''")}'`;
    const envPath = join(artifactRoot, "native-fixtures.env");
    await writeFile(envPath, `export IPAD_MIGRATION_NATIVE_CONFIG=${quoted}\nexport TEST_RUNNER_IPAD_MIGRATION_NATIVE_CONFIG=${quoted}\n`, {
      mode: 0o600,
    });
    checkpoint.status = "ready";
    await save();
    console.log(
      JSON.stringify({
        ready: true,
        configPath: join(artifactRoot, "native-config.json"),
        envPath,
        providerModes: configs.map((config) => `${config.type}:${config.mode}`),
        retained: true,
        checkpointPath,
        cleanup: "Stop this holder, then run the same command with --cleanup after verification",
      }),
    );
    await new Promise((resolve) => {
      process.once("SIGINT", resolve);
      process.once("SIGTERM", resolve);
    });
  }
} catch (error) {
  checkpoint.lastFailure = { errorClass: error.name, message: String(error.message).slice(0, 500), at: new Date().toISOString() };
  await save();
  console.error(
    JSON.stringify({
      retained: true,
      incomplete: true,
      checkpointPath,
      resume: "Run the same command with the same artifact directory",
      errorClass: error.name,
    }),
  );
  throw error;
} finally {
  await cleanupFixture([
    ...[...liveSources.entries()]
      .filter(([providerId]) => providerId === "audiobookshelf-api")
      .map(
        ([, source]) =>
          () =>
            source.close(),
      ),
    () => request("auth/logout", undefined, { refreshToken: owner.refreshToken }),
  ]);
}
