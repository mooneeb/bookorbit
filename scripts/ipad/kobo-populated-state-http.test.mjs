import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { createRequire } from "node:module";
import { resolve } from "node:path";
import { test } from "node:test";

const base = process.env.IPAD_E04_API_URL ?? "http://127.0.0.1:16502/api/v1";
if (!/^http:\/\/(localhost|127\.0\.0\.1):\d+\/api\/v1$/.test(base)) throw new Error("Populated Kobo tests require the isolated localhost harness");
const artifacts = resolve(process.env.IPAD_E04_ARTIFACTS_DIR ?? "test-results/ipad/kobo-scale");
const require = createRequire(new URL("../../server/package.json", import.meta.url));
const unzipper = require("unzipper");
const password = "IpadFixture123";

async function request(path, { token, method = "GET", body, headers = {} } = {}) {
  return fetch(`${base}/${path}`, {
    method,
    headers: { ...(token ? { authorization: `Bearer ${token}` } : {}), ...(body ? { "content-type": "application/json" } : {}), ...headers },
    ...(body ? { body: JSON.stringify(body) } : {}),
    signal: AbortSignal.timeout(60_000),
  });
}
async function json(path, options) {
  const response = await request(path, options);
  assert.ok(response.ok, `${path}: ${response.status} ${await response.clone().text()}`);
  return response.json();
}
async function observer(path) {
  await new Promise((resolve) => setTimeout(resolve, 350));
  return JSON.parse(await readFile(path, "utf8"));
}

test(
  "IPAD-E04-QA03-POPULATED Kobo fifty-book state page preserves bookmarks and real CFI mapping with bounded reads",
  { timeout: 180_000 },
  async () => {
    const fixture = JSON.parse(await readFile(resolve(artifacts, "e04-fixture.json"), "utf8"));
    assert.ok(fixture.koboScale?.eligibleCount >= 49_000, "The real EPUB scale corpus is required");
    const observerPath = process.env.IPAD_KOBO_QUERY_OBSERVER;
    assert.ok(observerPath, "Run this proof alone with the passive real-query observer");
    const owner = await json("auth/login", { method: "POST", body: { username: "ipad-owner", password } });
    const catalog = await json("books/query", {
      token: owner.accessToken,
      method: "POST",
      body: { q: fixture.koboScale.scopeTitlePrefix, sort: [{ field: "title", dir: "asc" }], pagination: { page: 0, size: 100 } },
    });
    const books = catalog.items.filter((book) => book.id >= fixture.koboScale.firstBookId).slice(0, 50);
    assert.equal(books.length, 50);
    const detail = await json(`books/${books[0].id}`, { token: owner.accessToken });
    const primary = detail.files.find((file) => file.id === detail.primaryFileId) ?? detail.files.find((file) => file.format === "epub");
    assert.ok(primary?.format === "epub");
    const username = `e04-kobo-state-${randomUUID().slice(0, 8)}`;
    const reader = await json("users", {
      token: owner.accessToken,
      method: "POST",
      body: {
        username,
        name: username,
        email: `${username}@example.test`,
        permissionNames: ["kobo_sync", "library_download"],
        libraryIds: [detail.libraryId],
      },
    });
    try {
      assert.equal(
        (
          await request("auth/reset-password", {
            method: "POST",
            body: { token: new URL(reader.resetUrl).searchParams.get("token"), newPassword: password },
          })
        ).status,
        204,
      );
      const session = await json("auth/login", { method: "POST", body: { username, password } });
      const token = session.accessToken;
      const device = await json("kobo/devices", { token, method: "POST", body: { name: "Fifty populated states" } });
      const collection = await json("collections", { token, method: "POST", body: { name: username, icon: "Folder", syncToKobo: true } });
      await json(`collections/${collection.id}/books`, { token, method: "POST", body: { bookIds: books.map((book) => book.id) } });
      await json("kobo/settings", { token, method: "PATCH", body: { twoWayProgressSync: false, convertToKepub: true, storeSync: false } });
      const expected = new Map();
      const modified = new Date(Date.now() - 60_000).toISOString();
      for (const [index, book] of books.entries()) {
        const marker = `state-${book.id}`;
        const state = {
          Created: modified,
          LastModified: modified,
          PriorityTimestamp: modified,
          CurrentBookmark: {
            LastModified: modified,
            ProgressPercent: 20 + index / 100,
            Location: { Source: "chapter.xhtml", Type: "KoboSpan", Value: marker },
          },
          Statistics: { LastModified: modified, RemainingBookTimeMinutes: index + 1 },
          StatusInfo: { LastModified: modified, Status: "Reading", TimesStartedReading: index + 1 },
        };
        const result = await json(`kobo/${device.token}/v1/library/${book.id}/state`, { method: "PUT", body: state });
        assert.equal(result.RequestResult, "Success");
        expected.set(book.title, state);
      }
      const cfi = "epubcfi(/6/2[c1ref]!/4/2[p1]/1:0)";
      const saved = await request(`books/files/${primary.id}/progress`, { token, method: "POST", body: { source: "text", cfi, percentage: 67.25 } });
      assert.ok(saved.ok, await saved.text());
      await json("kobo/settings", { token, method: "PATCH", body: { twoWayProgressSync: true } });
      const page = await json(`kobo/${device.token}/v1/library/sync`);
      const entries = page.filter((entry) => entry.NewEntitlement).map((entry) => entry.NewEntitlement);
      assert.equal(entries.length, 50, "All fifty requested books carry their persisted state in one public page");
      let mapped;
      for (const entry of entries) {
        const stored = expected.get(entry.BookMetadata.Title);
        assert.ok(stored, "No book outside the reader's selected collection is delivered");
        assert.deepEqual(entry.ReadingState.Statistics, stored.Statistics);
        assert.deepEqual(entry.ReadingState.StatusInfo, stored.StatusInfo);
        assert.equal(entry.ReadingState.EntitlementId, entry.BookEntitlement.Id);
        if (entry.BookMetadata.Title === books[0].title) mapped = entry;
        else assert.deepEqual(entry.ReadingState.CurrentBookmark, stored.CurrentBookmark);
      }
      assert.equal(mapped.ReadingState.CurrentBookmark.ProgressPercent, 67.25);
      assert.equal(mapped.ReadingState.CurrentBookmark.Location.Type, "KoboSpan");
      assert.match(mapped.ReadingState.CurrentBookmark.Location.Value, /^kobo\./);
      const progress = await json(`books/files/${primary.id}/progress`, { token });
      assert.equal(progress.cfi, cfi, "Conversion must preserve the actual canonical CFI");
      assert.equal(progress.koboLocationValue, mapped.ReadingState.CurrentBookmark.Location.Value);
      const delivery = mapped.BookMetadata.DownloadUrls.find((url) => url.Format === "KEPUB");
      assert.ok(delivery, "EPUB conversion settings must retain the device's kepub format mapping");
      const download = await fetch(delivery.Url, { signal: AbortSignal.timeout(60_000) });
      assert.equal(download.status, 200);
      const zip = await unzipper.Open.buffer(Buffer.from(await download.arrayBuffer()));
      const location = mapped.ReadingState.CurrentBookmark.Location;
      const chapter = zip.files.find((file) => file.path === location.Source || file.path.endsWith(`/${location.Source}`));
      assert.ok(chapter, "The returned bookmark chapter exists in the real delivered artifact");
      const content = (await chapter.buffer()).toString("utf8");
      assert.ok(
        content.includes(`id="${location.Value}"`) || content.includes(`id='${location.Value}'`),
        "The returned KoboSpan exists in the independently parsed kepub",
      );

      const before = await observer(observerPath);
      const started = performance.now();
      const retry = await json(`kobo/${device.token}/v1/library/sync`);
      const elapsedMs = performance.now() - started;
      assert.deepEqual(retry, page, "An unacknowledged populated page keeps all fifty states and stable CFI mapping");
      const after = await observer(observerPath);
      const limits = { readingStates: 1, settings: 5, identities: 4, progress: 2, files: 2, bookAccess: 12 };
      const queryDelta = {};
      for (const [category, limit] of Object.entries(limits)) {
        const previous = before.categories[category] ?? { queries: 0, returnedRows: 0 };
        const current = after.categories[category] ?? { queries: 0, returnedRows: 0 };
        queryDelta[category] = { queries: current.queries - previous.queries, returnedRows: current.returnedRows - previous.returnedRows };
        assert.ok(
          queryDelta[category].queries <= limit,
          `${category} made ${queryDelta[category].queries} queries for one populated fifty-book page`,
        );
      }
      assert.equal(queryDelta.readingStates.queries, 1);
      assert.equal(queryDelta.readingStates.returnedRows, 50);
      const responseBytes = Buffer.byteLength(JSON.stringify(retry));
      assert.ok(responseBytes < 250_000, "Populated page payload remains bounded");
      await mkdir(artifacts, { recursive: true });
      await writeFile(
        resolve(artifacts, "kobo-populated-state-evidence.json"),
        `${JSON.stringify({ testId: "IPAD-E04-QA03-POPULATED", pageBooks: entries.length, libraryBooks: catalog.total, elapsedMs, responseBytes, queryDelta, peakServerRssBytes: after.peakRssBytes, peakRssGrowthBytes: Math.max(0, after.peakRssBytes - before.peakRssBytes) }, null, 2)}\n`,
      );
    } finally {
      assert.equal((await request(`users/${reader.id}`, { token: owner.accessToken, method: "DELETE" })).status, 204);
    }
  },
);
