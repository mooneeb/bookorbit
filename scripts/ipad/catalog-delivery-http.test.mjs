import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { createHash, randomUUID } from "node:crypto";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { createRequire } from "node:module";
import { resolve } from "node:path";
import { test } from "node:test";
import { promisify } from "node:util";

const require = createRequire(new URL("../../server/package.json", import.meta.url));
const { PDFDocument, PDFDict, PDFName, PDFNumber } = require("pdf-lib");
const sharp = require("sharp");
const { XMLParser } = require("fast-xml-parser");
const execute = promisify(execFile);
const base = process.env.IPAD_E04_API_URL ?? "http://127.0.0.1:16502/api/v1";
const artifacts = resolve("test-results/ipad", process.env.IPAD_TEST_RUN ?? "e04-catalog-http", "catalog");
const username = `catalog-${randomUUID().slice(0, 8)}`;
const password = "CatalogReader123";
const protocol = { "x-auth-user": username, "x-auth-key": password };
const basic = { Authorization: `Basic ${Buffer.from(`${username}:${password}`).toString("base64")}` };

async function request(path, { token, body, method = body ? "POST" : "GET", headers = {} } = {}) {
  return fetch(`${base}/${path}`, {
    method,
    headers: { ...(token ? { Authorization: `Bearer ${token}` } : {}), ...(body ? { "Content-Type": "application/json" } : {}), ...headers },
    ...(body ? { body: JSON.stringify(body) } : {}),
    signal: AbortSignal.timeout(20_000),
    redirect: "error",
    cache: "no-store",
  });
}
async function json(path, options, status = 200) {
  const response = await request(path, options);
  assert.equal(response.status, status, await response.clone().text());
  return response.json();
}
async function login(username) {
  return json("auth/login", { body: { username, password: "IpadFixture123", clientKind: "native", deviceLabel: "Catalog public HTTP fixture" } });
}
const digest = (bytes) => `sha256:${createHash("sha256").update(bytes).digest("hex")}`;
function partialMD5(bytes) {
  const hash = createHash("md5");
  for (const offset of [0, 1024, 4096, 16384, 65536, 262144, 1048576, 4194304, 16777216, 67108864, 268435456, 1073741824]) {
    if (offset >= bytes.length) break;
    hash.update(bytes.subarray(offset, offset + 1024));
  }
  return hash.digest("hex");
}
async function delivered(path, headers) {
  const response = await request(path, { headers });
  assert.equal(response.status, 200, await response.clone().text());
  assert.equal(response.headers.get("cache-control"), "private, no-store");
  assert.ok(response.headers.get("etag"));
  const bytes = Buffer.from(await response.arrayBuffer());
  assert.equal(Number(response.headers.get("content-length")), bytes.length);
  assert.ok(bytes.length < 16 * 1024 * 1024, "fixture catalog artifacts remain bounded");
  return { bytes, etag: response.headers.get("etag") };
}
async function pdfItems(bytes) {
  const document = await PDFDocument.load(bytes);
  return document.getPages().flatMap((page) =>
    (page.node.Annots()?.asArray() ?? []).flatMap((reference) => {
      const annotation = document.context.lookup(reference);
      if (!(annotation instanceof PDFDict)) return [];
      const id = annotation.lookupMaybe(PDFName.of("BookOrbitAnnotationId"), PDFNumber)?.asNumber();
      return id == null ? [] : [{ id, annotation }];
    }),
  );
}
async function render(bytes, name) {
  await mkdir(artifacts, { recursive: true });
  const path = resolve(artifacts, `${name}.pdf`);
  const image = resolve(artifacts, name);
  await writeFile(path, bytes);
  await execute("/opt/homebrew/bin/pdftoppm", ["-f", "1", "-singlefile", "-scale-to-x", "600", "-scale-to-y", "800", "-png", path, image]);
  return sharp(await readFile(`${image}.png`))
    .removeAlpha()
    .raw()
    .toBuffer({ resolveWithObject: true });
}
function redPixelCount(image) {
  let count = 0;
  for (let y = 188; y < 212; y++) {
    for (let x = 75; x < 185; x++) {
      const at = (y * image.info.width + x) * image.info.channels;
      if (image.data[at] > 180 && image.data[at + 1] < 90 && image.data[at + 2] < 90) count++;
    }
  }
  return count;
}
async function source(token) {
  return json("annotations/native/files/1/source?bookId=1&page=0", { token });
}
async function operation(token, value) {
  const response = await json(
    "annotations/native/source-ink/1/1/operations",
    { token, body: { deviceId: "catalog-source-fixture", operations: [value] } },
    201,
  );
  const result = response.results[0];
  assert.equal(result.status, "applied");
  assert.equal(result.publication.status, "published");
  return result;
}

// The server, catalogs, publication, hashes and exchange are real. PDF rendering is independent Poppler.
test("IPAD-E04-A03/A04: scoped authenticated catalogs deliver current PDF ink/deletions and permitted exchange", async (t) => {
  const ownerSession = await login("ipad-owner");
  const catalogSession = await login("ipad-catalog");
  const otherSession = await login("ipad-reader");
  const restrictedSession = await login("ipad-restricted");
  const owner = ownerSession.accessToken;
  const token = catalogSession.accessToken;
  let accountID;
  let collectionID;
  let scopeID;
  let ink;
  let credentialsCreated = false;
  t.after(async () => {
    try {
      if (ink && !ink.annotation.deletedAt) {
        const descriptor = await source(owner);
        await operation(owner, {
          operationId: randomUUID(),
          clientId: ink.annotation.clientId,
          annotationId: ink.annotation.id,
          bookId: 1,
          baseVersion: ink.annotation.version,
          action: "delete",
          payload: { sourceRevision: descriptor.sourceRevision, pageFingerprint: descriptor.pageFingerprint },
        });
      }
      if (scopeID) assert.equal((await request(`smart-scopes/${scopeID}`, { token, method: "DELETE" })).status, 204);
      if (collectionID) assert.ok([200, 204].includes((await request(`collections/${collectionID}`, { token, method: "DELETE" })).status));
      if (accountID) assert.equal((await request(`opds-users/${accountID}`, { token, method: "DELETE" })).status, 204);
      if (credentialsCreated) assert.ok([200, 204].includes((await request("koreader/credentials", { token, method: "DELETE" })).status));
    } finally {
      for (const session of [ownerSession, catalogSession, otherSession, restrictedSession]) {
        assert.equal((await request("auth/logout", { body: { refreshToken: session.refreshToken } })).status, 200);
      }
    }
  });
  await json("koreader/credentials", { token, body: { username, password } }, 201);
  credentialsCreated = true;
  const account = await json("opds-users", { token, body: { username, password, sortOrder: "title_asc" } }, 201);
  accountID = account.id;
  assert.equal(account.userId, catalogSession.user.id);
  assert.equal((await request(`opds-users/${accountID}`, { token: owner, method: "DELETE" })).status, 403);
  assert.equal((await request("opds-users", { token: restrictedSession.accessToken })).status, 403);
  assert.equal((await request("koreader/sync-status", { token: restrictedSession.accessToken })).status, 403);
  const detail = await json("books/1", { token });
  const collectionName = `Catalog HTTP ${randomUUID().slice(0, 8)}`;
  const collection = await json("collections", { token, body: { name: collectionName, icon: "Folder", mediaType: "books", isPublic: false } }, 201);
  collectionID = collection.id;
  await json(`collections/${collectionID}/books`, { token, body: { bookIds: [1] } }, 201);
  const scope = await json(
    "smart-scopes",
    {
      token,
      body: {
        name: `Scope ${collectionName}`,
        icon: "filter",
        mediaType: "books",
        isPublic: false,
        filter: { type: "group", join: "AND", rules: [{ type: "rule", field: "title", operator: "eq", value: detail.title }] },
      },
    },
    201,
  );
  scopeID = scope.id;
  for (const filter of [`collectionId=${collectionID}`, `smartScopeId=${scopeID}`]) {
    const manifest = await json(`koreader/plugin/catalog/manifest?${filter}&size=20`, { headers: protocol });
    assert.deepEqual(
      manifest.items.map((book) => book.id),
      [1],
    );
    assert.equal(manifest.hasNext, false);
    assert.ok(manifest.items[0].files.some((file) => file.id === 1));
    const opds = await request(`opds/catalog?${filter}&size=20`, { headers: basic });
    assert.equal(opds.status, 200);
    const xml = await opds.text();
    const feed = new XMLParser({ ignoreAttributes: false }).parse(xml).feed;
    const entries = Array.isArray(feed.entry) ? feed.entry : feed.entry ? [feed.entry] : [];
    assert.equal(entries.length, 1);
    const links = Array.isArray(entries[0].link) ? entries[0].link : [entries[0].link];
    assert.ok(links.some((link) => link["@_href"]?.includes("/opds/1/download?fileId=1")));
    assert.match(xml, /opds\/1\/download\?fileId=1/);
  }
  assert.equal((await request("opds/1/download?fileId=1")).status, 401);
  assert.equal((await request("koreader/plugin/catalog/files/1/download")).status, 401);
  const routes = [
    ["opds/1/download?fileId=1", basic, "opds"],
    ["koreader/plugin/catalog/files/1/download", protocol, "koreader"],
  ];
  const before = await delivered(routes[0][0], routes[0][1]);
  const beforeIDs = (await pdfItems(before.bytes)).map((item) => item.id).sort((a, b) => a - b);
  const descriptor = await source(owner);
  assert.equal(digest(before.bytes), descriptor.sourceRevision);
  const initialRed = redPixelCount(await render(before.bytes, "before"));
  ink = await operation(owner, {
    operationId: randomUUID(),
    clientId: randomUUID(),
    bookId: 1,
    baseVersion: 0,
    action: "create",
    payload: {
      kind: "pdf_ink",
      bookFileId: 1,
      text: "",
      pdf: { page: 0, rect: { x: 76, y: 196, width: 108, height: 8 }, rects: [] },
      sourceRevision: descriptor.sourceRevision,
      pageFingerprint: descriptor.pageFingerprint,
      drawing: {
        format: "bookorbit-ink-v1",
        strokes: [
          {
            id: randomUUID(),
            width: 6,
            color: "#ff0000",
            points: [
              { x: 80, y: 200 },
              { x: 180, y: 200 },
            ],
          },
        ],
      },
    },
  });
  let currentHash;
  for (const [route, headers, name] of routes) {
    const marked = await delivered(route, { ...headers, "If-None-Match": before.etag });
    assert.equal(digest(marked.bytes), ink.publication.sourceRevision);
    assert.notEqual(digest(marked.bytes), digest(before.bytes));
    assert.notEqual(marked.etag, before.etag);
    const items = await pdfItems(marked.bytes);
    assert.ok(items.some((item) => item.id === ink.annotation.id));
    assert.ok(redPixelCount(await render(marked.bytes, `${name}-published`)) > initialRed + 200);
    currentHash = partialMD5(marked.bytes);
  }
  const savedProgress = await json("koreader/syncs/progress", {
    method: "PUT",
    headers: protocol,
    body: {
      document: currentHash,
      percentage: 0.5,
      progress: "2",
      device: "Catalog HTTP receiver",
      device_id: "catalog-http-device",
      timestamp: Date.now() / 1000,
    },
  });
  assert.ok(savedProgress);
  const pulled = await json(`koreader/syncs/progress/${currentHash}`, { headers: protocol });
  assert.equal(pulled.percentage, 0.5);
  assert.equal(pulled.progress, "2");
  const changed = await source(owner);
  ink = await operation(owner, {
    operationId: randomUUID(),
    clientId: ink.annotation.clientId,
    annotationId: ink.annotation.id,
    bookId: 1,
    baseVersion: ink.annotation.version,
    action: "delete",
    payload: { sourceRevision: changed.sourceRevision, pageFingerprint: changed.pageFingerprint },
  });
  for (const [route, headers, name] of routes) {
    const removed = await delivered(route, headers);
    assert.equal(digest(removed.bytes), ink.publication.sourceRevision);
    assert.notEqual(digest(removed.bytes), changed.sourceRevision);
    assert.deepEqual(
      (await pdfItems(removed.bytes)).map((item) => item.id).sort((a, b) => a - b),
      beforeIDs,
    );
    assert.equal(redPixelCount(await render(removed.bytes, `${name}-deleted`)), initialRed);
  }
  const epubResponse = await request("koreader/plugin/catalog/files/2/download", { headers: protocol });
  assert.equal(epubResponse.status, 200);
  const epubHash = partialMD5(Buffer.from(await epubResponse.arrayBuffer()));
  const device = { deviceId: "catalog-http-device", deviceModel: "Controlled KOReader protocol receiver", pluginVersion: "0.5.0" };
  const match = await json("koreader/plugin/match-check", { headers: protocol, body: { ...device, hashes: [epubHash] } }, 201);
  if (!match.matches.some((entry) => entry.hash === epubHash)) {
    await json(`koreader/unmatched-books/${epubHash}/link`, { token, body: { bookId: 2 } }, 201);
  }
  const incoming = {
    datetime: "2026-01-02 12:00:00",
    drawer: "lighten",
    color: "yellow",
    text: "Catalog text annotation",
    note: "Catalog note",
    posFormat: "xpointer",
    pos0: "/body/DocFragment[1]/body/p[1]/text().0",
    pos1: "/body/DocFragment[1]/body/p[1]/text().6",
  };
  const exchanged = await json(
    "koreader/plugin/annotations/exchange",
    { headers: protocol, body: { ...device, books: [{ hash: epubHash, keys: [], keysComplete: false, changes: [incoming] }] } },
    201,
  );
  assert.deepEqual(exchanged.unmatched, []);
  assert.equal(exchanged.results[0].bookId, 2);
  assert.equal(exchanged.results[0].applied.created, 1);
  const repeated = await json(
    "koreader/plugin/annotations/exchange",
    { headers: protocol, body: { ...device, books: [{ hash: epubHash, keys: [], keysComplete: false, changes: [incoming] }] } },
    201,
  );
  assert.equal(repeated.results[0].applied.created, 0);
  await mkdir(artifacts, { recursive: true });
  await writeFile(
    resolve(artifacts, "catalog-result.json"),
    JSON.stringify(
      {
        testId: "IPAD-E04-A03/A04",
        bookId: 1,
        fileId: 1,
        deletedInkId: ink.annotation.id,
        finalRevision: ink.publication.sourceRevision,
        progress: pulled.percentage,
        exchange: exchanged.results[0].applied,
      },
      null,
      2,
    ),
  );
});
