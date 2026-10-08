import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { mkdir, writeFile } from "node:fs/promises";
import { createRequire } from "node:module";
import { test } from "node:test";

const require = createRequire(new URL("../../server/package.json", import.meta.url));
const unzipper = require("unzipper");
const sharp = require("sharp");
const base = "http://localhost:16482/api/v1";
const artifacts = new URL(`../../test-results/ipad/${process.env.IPAD_TEST_RUN ?? `comic-http-${process.pid}`}/comic-http/`, import.meta.url);

async function request(path, { token, method = "GET", body } = {}) {
  return fetch(`${base}/${path}`, {
    method,
    headers: { ...(token ? { Authorization: `Bearer ${token}` } : {}), ...(body ? { "Content-Type": "application/json" } : {}) },
    ...(body ? { body: JSON.stringify(body) } : {}),
    signal: AbortSignal.timeout(15_000),
  });
}

async function login(username = "ipad-reader") {
  const response = await request("auth/login", {
    method: "POST",
    body: { username, password: "IpadFixture123", clientKind: "native", deviceLabel: "Comic HTTP QA" },
  });
  assert.equal(response.status, 200);
  return response.json();
}

async function logout(session) {
  assert.equal((await request("auth/logout", { method: "POST", body: { refreshToken: session.refreshToken } })).status, 200);
}

async function comicFile(token) {
  const response = await request("books/10", { token });
  assert.equal(response.status, 200);
  const file = (await response.json()).files.find((candidate) => candidate.format === "cbz");
  assert.ok(file);
  return file.id;
}

async function retain(name, value) {
  await mkdir(artifacts, { recursive: true });
  await writeFile(new URL(name, artifacts), value instanceof Uint8Array ? value : `${JSON.stringify(value, null, 2)}\n`);
}

test("IPAD-E01-A04/A05-comic-http: archive pages use natural order and retain authorization after cache priming", async () => {
  const reader = await login();
  const restricted = await login("ipad-restricted");
  const editor = await login("ipad-editor");
  try {
    const fileID = await comicFile(reader.accessToken);
    const route = `cbz/files/${fileID}/pages`;
    const count = await request(route, { token: reader.accessToken });
    assert.equal(count.status, 200);
    assert.deepEqual(await count.json(), { pageCount: 3 });
    const download = await request(`books/files/${fileID}/serve`, { token: reader.accessToken });
    assert.equal(download.status, 200);
    const archiveBytes = Buffer.from(await download.arrayBuffer());
    await retain("delivered.cbz", archiveBytes);
    const archive = await unzipper.Open.buffer(archiveBytes);
    assert.deepEqual(
      archive.files.map((entry) => entry.path),
      ["page-10.png", "page-2.png", "page-1.png"],
    );
    const report = [];
    for (const [index, name] of ["page-1.png", "page-2.png", "page-10.png"].entries()) {
      const response = await request(`${route}/${index}`, { token: reader.accessToken });
      assert.equal(response.status, 200);
      assert.match(response.headers.get("content-type"), /^image\/png/);
      const bytes = Buffer.from(await response.arrayBuffer());
      assert.deepEqual(bytes, await archive.files.find((entry) => entry.path === name).buffer());
      const metadata = await sharp(bytes).metadata();
      assert.deepEqual([metadata.width, metadata.height], [600, 800]);
      await retain(`natural-page-${index + 1}.png`, bytes);
      report.push({
        index,
        archiveEntry: name,
        width: metadata.width,
        height: metadata.height,
        sha256: createHash("sha256").update(bytes).digest("hex"),
      });
    }
    await retain("natural-order.json", report);
    for (const suffix of ["", "/0"]) {
      assert.equal((await request(`${route}${suffix}`)).status, 401);
      assert.equal((await request(`${route}${suffix}`, { token: restricted.accessToken })).status, 403);
      assert.equal((await request(`${route}${suffix}`, { token: editor.accessToken })).status, 200);
    }
    for (const index of [-1, 3, 100_000]) assert.equal((await request(`${route}/${index}`, { token: reader.accessToken })).status, 404);
    for (const index of ["1.5", "NaN"]) assert.equal((await request(`${route}/${index}`, { token: reader.accessToken })).status, 400);
  } finally {
    for (const session of [reader, restricted, editor]) await logout(session);
  }
});

test("IPAD-E01-A05-comic-cache: authenticated private page images cannot be stored by a shared cache", async () => {
  const reader = await login();
  try {
    const fileID = await comicFile(reader.accessToken);
    const response = await request(`cbz/files/${fileID}/pages/0`, { token: reader.accessToken });
    assert.equal(response.status, 200);
    const cacheControl = response.headers.get("cache-control");
    await retain("cache-policy.json", { status: response.status, cacheControl, contentType: response.headers.get("content-type") });
    await response.arrayBuffer();
    assert.match(cacheControl, /(?:^|,)\s*private(?:,|$)/);
    assert.match(cacheControl, /(?:^|,)\s*no-store(?:,|$)/);
  } finally {
    await logout(reader);
  }
});

test("IPAD-E01-A03/A04/A05-comic-progress: text replacement preserves independent narration and user scope", async () => {
  const reader = await login();
  const narration = await login();
  const editor = await login("ipad-editor");
  const restricted = await login("ipad-restricted");
  const fileID = await comicFile(reader.accessToken);
  const route = `books/files/${fileID}/progress`;
  const save = async (token, body) => assert.equal((await request(route, { token, method: "POST", body })).status, 201);
  const read = async (token) => {
    const response = await request(route, { token });
    assert.equal(response.status, 200);
    return response.json();
  };
  try {
    assert.equal((await request(route, { token: reader.accessToken, method: "DELETE" })).status, 204);
    assert.equal((await request(route, { token: editor.accessToken, method: "DELETE" })).status, 204);
    await save(reader.accessToken, {
      source: "text",
      percentage: 100 / 3,
      pageNumber: 1,
      cfi: "epubcfi(/6/2[c1ref]!/4/2[p1],/1:0,/1:5)",
      koboLocationSource: "OPS/c1.xhtml",
      koboLocationType: "KoboSpan",
      koboLocationValue: "kobo.1.1",
      koboContentSourceProgressPercent: 25,
      koreaderProgress: "/body/DocFragment[1]/body/p[1]/text().0",
    });
    const before = await read(reader.accessToken);
    assert.equal(before.koreaderProgress, "/body/DocFragment[1]/body/p[1]/text().0");
    assert.equal(before.koboLocationValue, "kobo.1.1");
    assert.ok(before.cfi);
    await retain("progress-before.json", before);
    await save(narration.accessToken, {
      source: "narration",
      percentage: 20,
      positionSeconds: 9,
      mediaOverlayFragment: "chapter-one.xhtml#second",
      mediaOverlaySectionIndex: 0,
    });
    await save(reader.accessToken, { source: "text", percentage: 200 / 3, pageNumber: 2 });
    const after = await read(reader.accessToken);
    await retain("progress-after.json", after);
    assert.equal(after.pageNumber, 2);
    assert.ok(Math.abs(after.percentage - 200 / 3) < 0.01);
    for (const field of [
      "cfi",
      "koboLocationSource",
      "koboLocationType",
      "koboLocationValue",
      "koboContentSourceProgressPercent",
      "koreaderProgress",
    ])
      assert.equal(after[field], null);
    assert.equal(after.positionSeconds, 9);
    assert.equal(after.mediaOverlayFragment, "chapter-one.xhtml#second");
    assert.equal(after.mediaOverlaySectionIndex, 0);
    assert.equal(after.narrationPercentage, 20);
    const independent = await read(editor.accessToken);
    assert.equal(independent.pageNumber, null);
    assert.equal(independent.positionSeconds, null);
    assert.equal((await request(route, { token: restricted.accessToken })).status, 403);
    assert.equal(
      (await request(route, { token: restricted.accessToken, method: "POST", body: { source: "text", percentage: 100, pageNumber: 3 } })).status,
      403,
    );
    assert.deepEqual(await read(reader.accessToken), after);
  } finally {
    for (const session of [reader, editor]) assert.equal((await request(route, { token: session.accessToken, method: "DELETE" })).status, 204);
    for (const session of [reader, narration, editor, restricted]) await logout(session);
  }
});
