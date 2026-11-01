import assert from "node:assert/strict";
import { readFile, writeFile } from "node:fs/promises";
import { connect } from "node:net";
import { execFileSync } from "node:child_process";
import { resolve } from "node:path";

const output = resolve(process.argv[2] ?? "native/build/qa-profile");
const ready = JSON.parse(await readFile(resolve(output, "ready.json"), "utf8"));
const profile = JSON.parse(await readFile(resolve(output, "profile.json"), "utf8"));
assert.equal(ready.books, 50_000);
assert.equal(ready.annotations, 100_000);
assert.equal(ready.storage, "disk");
assert.equal(profile.memoryMax, "8589934592");
const [quota, period] = profile.cpuMax.split(" ").map(Number);
assert.equal(quota / period, 4);
assert.match(profile.sourceCommit, /^[a-f0-9]{40}$/);
assert.equal(profile.sourceCommit, execFileSync("git", ["rev-parse", "HEAD"], { encoding: "utf8" }).trim());
assert.equal(execFileSync("git", ["status", "--porcelain"], { encoding: "utf8" }).trim(), "");

const linkMbps = async () =>
  new Promise((accept, reject) => {
    const started = performance.now();
    let bytes = 0;
    const socket = connect(55459, "127.0.0.1");
    socket.setTimeout(10_000, () => socket.destroy(new Error("Link probe timeout")));
    socket.on("data", (data) => {
      bytes += data.length;
    });
    socket.on("error", reject);
    socket.on("end", () => {
      try {
        assert.equal(bytes, 32 * 1024 * 1024);
        accept((bytes * 8) / ((performance.now() - started) / 1000) / 1_000_000);
      } catch (error) {
        reject(error);
      }
    });
  });
await linkMbps();
const linkRuns = [];
for (let run = 0; run < 3; run++) linkRuns.push(await linkMbps());

const base = "http://127.0.0.1:55458/api/v1";
let token;
const request = async (path, body) => {
  const response = await fetch(base + path, {
    method: body ? "POST" : "GET",
    cache: "no-store",
    signal: AbortSignal.timeout(10_000),
    headers: { "Content-Type": "application/json", Connection: "close", ...(token ? { Authorization: `Bearer ${token}` } : {}) },
    ...(body ? { body: JSON.stringify(body) } : {}),
  });
  if (!response.ok) throw new Error(`${path}: HTTP ${response.status}`);
  return response.json();
};
token = (
  await request("/auth/login", {
    username: "reader-a@example.test",
    password: "ReaderA-QA-24!",
    clientKind: "native",
    deviceLabel: "Isolated catalog benchmark",
  })
).accessToken;
assert.ok(token);
assert.equal((await request("/auth/me")).id, ready.accountId);
const page = async (index, q = "") => {
  const result = await request("/books/query", { q, sort: [{ field: "title", dir: "asc" }], pagination: { page: index, size: 50 } });
  assert.ok(result.items.length <= 100);
  assert.ok(result.items.every((book) => book.title !== "B Secret"));
  return result.items;
};
const ids = new Set();
for (let index = 0; index < 3; index++) {
  const items = await page(index);
  assert.equal(items.length, 50);
  for (const book of items) ids.add(book.id);
}
assert.equal(ids.size, 150);
assert.deepEqual(
  (await page(0, "QA Prose")).map((book) => book.title),
  ["QA Prose"],
);
assert.deepEqual(await page(0, "B Secret"), []);
const first = [],
  next = [],
  failures = [];
for (let run = 0; run < 30; run++) {
  for (const [index, times] of [
    [0, first],
    [1, next],
  ]) {
    const started = performance.now();
    try {
      await page(index);
      times.push(performance.now() - started);
    } catch (error) {
      failures.push({ run, page: index, error: error.message });
    }
  }
}
const stats = (values) => {
  const sorted = [...values].sort((a, b) => a - b);
  return { p50: sorted[Math.ceil(sorted.length * 0.5) - 1], p95: sorted[Math.ceil(sorted.length * 0.95) - 1], samples: values };
};
const result = {
  profile,
  dataset: { books: ready.books, annotations: ready.annotations },
  runs: 30,
  firstPage: stats(first),
  nextPage: stats(next),
  failures,
  linkMbps: linkRuns,
  conditions:
    "API and PostgreSQL share one four-core/eight-GiB cgroup. New HTTP connection per request; no client response cache; PostgreSQL and filesystem buffers retained after seed/ANALYZE. Docker bridge published on loopback; throughput probe recorded separately. TLS is not part of this test adapter.",
};
await writeFile(resolve(output, "catalog-results.json"), JSON.stringify(result, null, 2) + "\n");
console.log(
  JSON.stringify({ ...result, firstPage: { ...result.firstPage, samples: undefined }, nextPage: { ...result.nextPage, samples: undefined } }),
);
assert.equal(failures.length, 0);
assert.equal(first.length, 30);
assert.equal(next.length, 30);
assert.ok(Math.min(...linkRuns) >= 100, "Client link must sustain at least 100 Mbit/s");
assert.ok(result.firstPage.p95 <= 2000, "First-page p95 exceeds two seconds");
assert.ok(result.nextPage.p95 <= 1000, "Next-page p95 exceeds one second");
