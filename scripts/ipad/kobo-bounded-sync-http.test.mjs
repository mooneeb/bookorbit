import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { resolve } from "node:path";
import { test } from "node:test";

const base = process.env.IPAD_E04_API_URL ?? "http://127.0.0.1:16502/api/v1";
const artifacts = resolve(process.env.IPAD_E04_ARTIFACTS_DIR ?? "test-results/ipad/kobo-scale");

async function request(path, token, method = "GET", body, headers = {}) {
  return fetch(`${base}/${path}`, {
    method,
    headers: { ...(token ? { authorization: `Bearer ${token}` } : {}), ...(body ? { "content-type": "application/json" } : {}), ...headers },
    ...(body ? { body: JSON.stringify(body) } : {}),
    signal: AbortSignal.timeout(60_000),
  });
}
async function json(path, token, method = "GET", body, headers) {
  const response = await request(path, token, method, body, headers);
  assert.ok(response.ok, `${method} ${path}: ${await response.clone().text()}`);
  return response.json();
}

test("IPAD-E04-QA03 Kobo catalog batches, interrupted tag stream and retry converge in a 50,000-book library", { timeout: 300_000 }, async () => {
  const fixture = JSON.parse(await readFile(resolve(artifacts, "e04-fixture.json"), "utf8"));
  const scale = fixture.koboScale;
  assert.ok(scale?.eligibleCount >= 49_000, "Enable IPAD_KOBO_SCALE_FIXTURE for the real content corpus");
  const observerPath = process.env.IPAD_KOBO_QUERY_OBSERVER;
  assert.ok(observerPath, "The passive real-query observer is required for deterministic batch bounds");
  const login = await json("auth/login", undefined, "POST", { username: "ipad-owner", password: "IpadFixture123" });
  const token = login.accessToken;
  const catalog = await json("books/query", token, "POST", { sort: [], pagination: { page: 0, size: 1 } });
  assert.ok(catalog.total >= 50_000, "Public library browsing confirms the scale corpus");
  const device = await json("kobo/devices", token, "POST", { name: `Kobo scale ${randomUUID()}` });
  const scope = await json("smart-scopes", token, "POST", {
    name: `Kobo scale ${randomUUID()}`,
    icon: "Filter",
    syncToKobo: true,
    filter: {
      type: "group",
      join: "AND",
      rules: [
        { type: "rule", field: "title", operator: "startsWith", value: scale.scopeTitlePrefix },
        { type: "rule", field: "format", operator: "includesAny", value: ["epub"] },
      ],
    },
  });
  let cursor;
  const seen = new Set();
  const durations = [];
  let firstDownload;
  const start = performance.now();
  try {
    for (let page = 0; page < 1200; page++) {
      const pageStart = performance.now();
      const response = await request(
        `kobo/${device.token}/v1/library/sync`,
        undefined,
        "GET",
        undefined,
        cursor ? { "x-kobo-synctoken": cursor } : {},
      );
      assert.equal(response.status, 200);
      const entries = await response.json();
      durations.push(performance.now() - pageStart);
      const books = entries.filter((entry) => entry.NewEntitlement || entry.ChangedProductMetadata);
      assert.ok(books.length <= 50, "Every catalog page is bounded at 50 book entries");
      for (const entry of books) {
        const book = entry.NewEntitlement ?? entry.ChangedProductMetadata;
        if (!book.BookMetadata.Title.startsWith(scale.scopeTitlePrefix) || book.BookMetadata.DownloadUrls[0].Format === "PDF") continue;
        assert.equal(seen.has(book.BookEntitlement.Id), false, "Acknowledged catalog pages advance once");
        seen.add(book.BookEntitlement.Id);
        firstDownload ??= book.BookMetadata.DownloadUrls[0].Url;
      }
      cursor = response.headers.get("x-kobo-synctoken");
      if (response.headers.get("x-kobo-sync") !== "continue") break;
      assert.ok(page < 1199, "Catalog sync must converge within its expected page bound");
    }
    assert.equal(seen.size, scale.eligibleCount);
    assert.ok(firstDownload);
    const delivered = await fetch(firstDownload, { signal: AbortSignal.timeout(60_000) });
    assert.equal(delivered.status, 200);
    const bytes = new Uint8Array(await delivered.arrayBuffer());
    assert.ok(bytes.length > 100);
    assert.deepEqual([...bytes.subarray(0, 2)], [0x50, 0x4b], "The independently selected scale book delivers an actual EPUB ZIP artifact");

    const abort = new AbortController();
    const interrupted = await fetch(`${base}/kobo/${device.token}/v1/library/sync`, {
      headers: { "x-kobo-synctoken": cursor },
      signal: abort.signal,
    });
    assert.equal(interrupted.status, 200);
    const reader = interrupted.body.getReader();
    const prefix = await reader.read();
    assert.ok(prefix.value?.length > 0 && !prefix.done);
    abort.abort();
    await reader.cancel().catch(() => {});
    const retry = await json(`kobo/${device.token}/v1/library/sync`, undefined, "GET", undefined, { "x-kobo-synctoken": cursor });
    const tag = retry.find((entry) => entry.ChangedTag?.Tag.Id === `ss-${scope.id}`)?.ChangedTag.Tag;
    assert.equal(tag.Items.length, scale.eligibleCount, "Retry resends the complete tag replacement after interruption");
    assert.deepEqual(new Set(tag.Items.map((item) => item.RevisionId)), seen);
    assert.ok(!retry.some((entry) => entry.NewEntitlement), "Tag retry does not reannounce acknowledged books");
    const history = await json("kobo/history?limit=100", token);
    assert.ok(
      history.some((entry) => entry.deviceId === device.id && entry.status === "failed"),
      "An interrupted stream is recorded as failed",
    );

    const evidence = JSON.parse(await readFile(observerPath, "utf8"));
    assert.ok(evidence.categories.catalog?.queries >= 10);
    assert.ok(evidence.categories.catalog.maxRows <= 5000);
    assert.ok(evidence.categories.tags?.maxRows <= 5000);
    assert.ok(evidence.categories.pending?.maxRows <= 51);
    const elapsedMs = performance.now() - start;
    assert.ok(elapsedMs < 240_000, `50,000-book sync exceeded the explicit 240s HTTP regression budget: ${elapsedMs}ms`);
    assert.ok(Math.max(...durations) < 30_000, "Each individual sync request stays below the 30s server budget");
    await mkdir(artifacts, { recursive: true });
    await writeFile(
      resolve(artifacts, "kobo-scale-evidence.json"),
      `${JSON.stringify({ testId: "IPAD-E04-QA03", libraryBooks: catalog.total, deliveredBooks: seen.size, pages: durations.length, elapsedMs, maxPageMs: Math.max(...durations), budgetMs: 240_000, queryEvidence: evidence }, null, 2)}\n`,
    );
  } finally {
    await request(`smart-scopes/${scope.id}`, token, "DELETE");
    await request(`kobo/devices/${device.id}`, token, "DELETE");
  }
});
