import { createHash, randomUUID } from "node:crypto";
import { createRequire } from "node:module";
import { execFile } from "node:child_process";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { resolve } from "node:path";
import { promisify } from "node:util";
import assert from "node:assert/strict";
import { before, test } from "node:test";

const require = createRequire(new URL("../../server/package.json", import.meta.url));
const { PDFDocument, PDFDict, PDFName, PDFString, PDFHexString } = require("pdf-lib");
const sharp = require("sharp");
const execute = promisify(execFile);
const artifacts = resolve("test-results/ipad", process.env.IPAD_TEST_RUN ?? "kobo-http", "kobo-artifacts");

async function renderedPixel(bytes, name) {
  await mkdir(artifacts, { recursive: true });
  const path = resolve(artifacts, `${name}.pdf`);
  const imagePath = resolve(artifacts, name);
  await writeFile(path, bytes);
  await execute("/opt/homebrew/bin/pdftoppm", ["-f", "1", "-singlefile", "-scale-to-x", "600", "-scale-to-y", "800", "-png", path, imagePath]);
  const image = await sharp(await readFile(`${imagePath}.png`))
    .removeAlpha()
    .raw()
    .toBuffer({ resolveWithObject: true });
  assert.equal(image.info.width, 600);
  assert.equal(image.info.height, 800);
  const offset = (650 * image.info.width + 480) * image.info.channels;
  return [...image.data.subarray(offset, offset + 3)];
}

let base;
let owner;
let restricted;

async function request(path, token, method = "GET", body) {
  const response = await fetch(`${base}/api/v1/${path}`, {
    method,
    headers: { ...(token ? { authorization: `Bearer ${token}` } : {}), ...(body ? { "content-type": "application/json" } : {}) },
    ...(body ? { body: JSON.stringify(body) } : {}),
    signal: AbortSignal.timeout(20_000),
  });
  return response;
}

async function json(path, token, method = "GET", body) {
  const response = await request(path, token, method, body);
  assert.equal(response.ok, true, `${method} ${path}: ${await response.clone().text()}`);
  return response.json();
}

before(async () => {
  const target = process.env.IPAD_E04_BASE_URL;
  if (!target || !["localhost", "127.0.0.1"].includes(new URL(target).hostname)) {
    throw new Error("Kobo HTTP tests require IPAD_E04_BASE_URL for the isolated real iPad harness");
  }
  base = target.replace(/\/$/, "");
  for (const username of ["ipad-owner", "ipad-restricted"]) {
    const login = await json("auth/login", undefined, "POST", { username, password: "IpadFixture123" });
    if (username === "ipad-owner") owner = login.accessToken;
    else restricted = login.accessToken;
  }
});

test("IPAD-E04-A03 Kobo subscriptions require permission while ordinary owned collection edits remain available", async () => {
  const name = `Kobo permission ${randomUUID()}`;
  assert.equal((await request("collections", restricted, "POST", { name, icon: "Folder", syncToKobo: true })).status, 403);
  const collection = await json("collections", restricted, "POST", { name, icon: "Folder" });
  try {
    assert.equal((await request(`collections/${collection.id}`, restricted, "PATCH", { syncToKobo: true })).status, 403);
    assert.equal((await request(`collections/${collection.id}`, restricted, "PATCH", { syncToKobo: false })).status, 200);
    const renamed = await json(`collections/${collection.id}`, restricted, "PATCH", { name: `${name} renamed` });
    assert.equal(renamed.syncToKobo, false);
    assert.equal((await request(`collections/${collection.id}`, owner, "PATCH", { syncToKobo: true })).status, 200);
    assert.equal((await request(`collections/${collection.id}`, restricted, "PATCH", { syncToKobo: false })).status, 403);
    assert.equal((await request("kobo/devices", restricted)).status, 403);
    assert.equal((await request("kobo/history", restricted)).status, 403);
  } finally {
    assert.equal((await request(`collections/${collection.id}`, restricted, "DELETE")).status, 204);
  }
});

test("IPAD-E04-A04 Kobo redelivery contains published source ink and its committed deletion with current revision", async () => {
  const bookID = 1;
  const fileID = 1;
  const detail = await json(`books/${bookID}`, owner);
  const username = `kobo-delivery-isolated-${randomUUID().slice(0, 8)}`;
  const reader = await json("users", owner, "POST", {
    username,
    name: username,
    email: `${username}@example.test`,
    permissionNames: ["kobo_sync", "library_download", "library_edit_metadata", "annotation_manage_own"],
    libraryIds: [detail.libraryId],
  });
  assert.equal(
    (
      await request("auth/reset-password", undefined, "POST", {
        token: new URL(reader.resetUrl).searchParams.get("token"),
        newPassword: "IpadFixture123",
      })
    ).status,
    204,
  );
  const readerToken = (await json("auth/login", undefined, "POST", { username, password: "IpadFixture123" })).accessToken;
  const device = await json("kobo/devices", readerToken, "POST", { name: `Kobo artifact ${randomUUID()}` });
  const collection = await json("collections", readerToken, "POST", { name: `Kobo source ${randomUUID()}`, icon: "Folder", syncToKobo: true });
  const clientId = randomUUID();
  let entitlement;
  let cursor;
  const sync = async () => {
    const response = await fetch(`${base}/api/v1/kobo/${device.token}/v1/library/sync`, {
      headers: cursor ? { "x-kobo-synctoken": cursor } : {},
      signal: AbortSignal.timeout(20_000),
    });
    assert.equal(response.status, 200);
    const entries = await response.json();
    cursor = response.headers.get("x-kobo-synctoken");
    assert.ok(entries.filter((entry) => entry.NewEntitlement || entry.ChangedProductMetadata).length <= 50);
    return entries;
  };
  let annotation;
  const source = () => json(`annotations/native/files/${fileID}/source?bookId=${bookID}&page=0`, readerToken);
  const mutate = async (action, payload) => {
    const result = await json(`annotations/native/source-ink/${bookID}/${fileID}/operations`, readerToken, "POST", {
      deviceId: "Kobo-controlled-protocol",
      operations: [
        {
          operationId: randomUUID(),
          clientId,
          bookId: bookID,
          baseVersion: annotation?.version ?? 0,
          action,
          ...(annotation ? { annotationId: annotation.id } : {}),
          payload,
        },
      ],
    });
    assert.equal(result.results[0]?.status, "applied");
    assert.equal(result.results[0]?.publication.status, "published");
    annotation = result.results[0].annotation;
  };
  const download = async () => {
    const response = await request(`kobo/${device.token}/v1/books/${entitlement}/download`);
    assert.equal(response.status, 200);
    assert.ok(response.headers.get("content-type").includes("application/pdf"));
    assert.ok(response.headers.get("cache-control").includes("no-store"));
    const bytes = new Uint8Array(await response.arrayBuffer());
    const revision = `sha256:${createHash("sha256").update(bytes).digest("hex")}`;
    assert.equal(response.headers.get("x-bookorbit-source-revision"), revision);
    assert.equal(response.headers.get("etag"), `"${revision}"`);
    assert.equal(revision, (await source()).sourceRevision);
    return bytes;
  };
  const hasInk = async (bytes) => {
    const document = await PDFDocument.load(bytes);
    const annotations = document.getPage(0).node.Annots();
    if (!annotations) return false;
    for (let index = 0; index < annotations.size(); index++) {
      const dict = document.context.lookup(annotations.get(index), PDFDict);
      const identity = dict.get(PDFName.of("NM"));
      if ((identity instanceof PDFString || identity instanceof PDFHexString) && identity.decodeText() === `bookorbit:${annotation.id}`) return true;
    }
    return false;
  };
  try {
    await json(`collections/${collection.id}/books`, readerToken, "POST", { bookIds: [bookID] });
    const initial = await sync();
    entitlement =
      initial.find((entry) => entry.NewEntitlement?.BookMetadata?.Title === "Orbit fixture")?.NewEntitlement?.BookEntitlement?.Id ??
      initial.find((entry) => entry.NewEntitlement?.BookMetadata?.DownloadUrls?.[0]?.Format === "PDF")?.NewEntitlement?.BookEntitlement?.Id;
    assert.ok(entitlement, "A subscribed source PDF must have a Kobo entitlement");
    assert.equal(
      (await sync()).some((entry) => entry.NewEntitlement || entry.ChangedProductMetadata),
      false,
    );
    const descriptor = await source();
    await mutate("create", {
      kind: "pdf_ink",
      bookFileId: fileID,
      text: "",
      sourceRevision: descriptor.sourceRevision,
      pageFingerprint: descriptor.pageFingerprint,
      pdf: { page: 0, rect: { x: 426, y: 646, width: 108, height: 8 }, rects: [] },
      drawing: {
        format: "bookorbit-ink-v1",
        strokes: [
          {
            id: clientId,
            color: "#ff0000",
            width: 5,
            points: [
              { x: 430, y: 650 },
              { x: 530, y: 650 },
            ],
          },
        ],
      },
    });
    assert.ok(
      (await sync()).some((entry) => entry.NewEntitlement?.BookEntitlement?.Id === entitlement),
      "Published ink must reannounce the source PDF",
    );
    const marked = await download();
    assert.equal(await hasInk(marked), true);
    const markPixel = await renderedPixel(marked, "IPAD-E04-A04-kobo-published-ink");
    assert.ok(markPixel[0] > 220 && markPixel[1] < 80 && markPixel[2] < 80, "An independent PDF renderer must show the red source ink");
    const current = await source();
    await mutate("delete", { sourceRevision: current.sourceRevision, pageFingerprint: current.pageFingerprint });
    assert.ok(
      (await sync()).some((entry) => entry.NewEntitlement?.BookEntitlement?.Id === entitlement),
      "Committed ink deletion must reannounce the source PDF",
    );
    const deleted = await download();
    assert.equal(await hasInk(deleted), false);
    const deletedPixel = await renderedPixel(deleted, "IPAD-E04-A04-kobo-deleted-ink");
    assert.ok(
      deletedPixel.every((channel) => channel > 220),
      "An independent PDF renderer must show the deleted ink area as blank",
    );
    assert.notDeepEqual(deleted, marked);
    let history = [];
    const deadline = Date.now() + 5000;
    do {
      history = await json("kobo/history?limit=100", readerToken);
      if (history.filter((entry) => entry.deviceId === device.id && entry.event === "book_download").length === 2) break;
      await new Promise((resolve) => setTimeout(resolve, 50));
    } while (Date.now() < deadline);
    assert.equal(history.filter((entry) => entry.deviceId === device.id && entry.event === "book_download").length, 2);
    assert.equal(
      history.filter((entry) => entry.deviceId === device.id).every((entry) => entry.status === "success"),
      true,
    );
    assert.equal((await request(`kobo/devices/${device.id}`, restricted, "DELETE")).status, 403);
    assert.equal((await request(`kobo/devices/${device.id}`, readerToken, "DELETE")).status, 204);
    assert.equal((await request(`kobo/${device.token}/v1/books/${entitlement}/download`)).status, 401);
  } finally {
    if (annotation && !annotation.deletedAt) {
      const current = await source();
      await mutate("delete", { sourceRevision: current.sourceRevision, pageFingerprint: current.pageFingerprint });
    }
    await request(`collections/${collection.id}`, readerToken, "DELETE");
    await request(`kobo/devices/${device.id}`, readerToken, "DELETE");
    assert.equal((await request(`users/${reader.id}`, owner, "DELETE")).status, 204);
  }
});
