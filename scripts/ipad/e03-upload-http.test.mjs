import assert from "node:assert/strict";
import { test } from "node:test";
import { writeFile } from "node:fs/promises";
import { createRequire } from "node:module";
const { PDFDocument, StandardFonts } = createRequire(new URL("../../server/package.json", import.meta.url))("pdf-lib");

const base = process.env.IPAD_E03_API_URL ?? "http://localhost:16482/api/v1";
async function request(path, token, body, method = body ? "POST" : "GET") {
  return fetch(`${base}/${path}`, {
    method,
    headers: { ...(token ? { Authorization: `Bearer ${token}` } : {}), ...(body ? { "Content-Type": "application/json" } : {}) },
    body: body ? JSON.stringify(body) : undefined,
  });
}
async function json(path, token, body, method) {
  const response = await request(path, token, body, method);
  assert.ok(response.ok, `${path}: ${response.status} ${await response.clone().text()}`);
  return response.json();
}
async function login(username) {
  return json("auth/login", undefined, {
    username,
    password: process.env.IPAD_FIXTURE_PASSWORD ?? "IpadFixture123",
    clientKind: "native",
    deviceLabel: "E03 upload HTTP",
  });
}
async function eventually(operation) {
  const deadline = Date.now() + 30_000;
  while (Date.now() < deadline) {
    const result = await operation();
    if (result) return result;
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  assert.fail("Import did not become ready");
}

test("IPAD-E03-A01-upload: interrupted chunks resume, metadata/destination review, finalize retry returns one readable import", async () => {
  const owner = await login(process.env.IPAD_UPLOAD_USER ?? "ipad-editor");
  const other = await login("ipad-restricted");
  const token = owner.accessToken;
  try {
    const caps = await json("uploads/capabilities", token);
    assert.equal(caps.canUseBookDock, true);
    assert.equal(caps.canUploadToLibrary, true);
    const library = caps.libraries.find((item) => item.name === "Fixture library") ?? caps.libraries[0];
    assert.ok(library?.folders[0]);
    const id = crypto.randomUUID();
    const filename = `Native upload ${id}.pdf`;
    const document = await PDFDocument.create();
    const font = await document.embedFont(StandardFonts.Helvetica);
    document.addPage([300, 400]).drawText("Native upload reader handoff", { x: 20, y: 350, font });
    const bytes = await document.save();
    const payload = { filename, sizeBytes: bytes.length, idempotencyKey: id, target: { kind: "book_dock" } };
    assert.equal((await request("uploads", other.accessToken, payload)).status, 403);
    let session = await json("uploads", token, payload);
    assert.equal((await json("uploads", token, payload)).id, session.id);
    assert.equal((await request(`uploads/${session.id}`, other.accessToken)).status, 404);
    assert.equal((await request("uploads", token, { ...payload, unexpected: true })).status, 400);
    async function chunk(offset, data) {
      const form = new FormData();
      form.append("file", new Blob([data]), "chunk");
      return fetch(`${base}/uploads/${session.id}/chunks`, {
        method: "POST",
        headers: { Authorization: `Bearer ${token}`, "Upload-Offset": String(offset) },
        body: form,
      });
    }
    const midpoint = Math.floor(bytes.length / 2);
    assert.equal((await chunk(0, bytes.slice(0, midpoint))).status, 201);
    session = await json(`uploads/${session.id}`, token);
    assert.equal(session.receivedBytes, midpoint);
    assert.equal((await chunk(0, bytes.slice(0, midpoint))).status, 409);
    assert.equal((await chunk(session.receivedBytes, bytes.slice(midpoint))).status, 201);
    session = await json(`uploads/${session.id}/complete`, token, {});
    assert.equal(session.status, "completed");
    assert.ok(session.bookDockFileId);
    assert.equal((await json(`uploads/${session.id}/complete`, token, {})).bookDockFileId, session.bookDockFileId);
    const dock = await eventually(async () => {
      const item = await json(`book-dock/files/${session.bookDockFileId}`, token);
      return item.status === "ready" ? item : null;
    });
    const title = `Reviewed native ${id}`;
    await json(
      `book-dock/files/${dock.id}`,
      token,
      {
        expectedUpdatedAt: dock.updatedAt,
        selectedMetadata: { title, authors: ["Native reader"] },
        targetLibraryId: library.id,
        targetFolderId: library.folders[0].id,
      },
      "PATCH",
    );
    assert.equal(
      (
        await request(
          `book-dock/files/${dock.id}`,
          token,
          { expectedUpdatedAt: dock.updatedAt, selectedMetadata: { title: "Stale overwrite" } },
          "PATCH",
        )
      ).status,
      409,
    );
    assert.equal((await json(`book-dock/files/${dock.id}`, token)).selectedMetadata.title, title);
    const selection = { fileIds: [dock.id] };
    const preview = await json("book-dock/finalize/preview", token, selection);
    assert.equal(preview.ready, 1);
    const [finalized, simultaneous] = await Promise.all([json("book-dock/finalize", token, selection), json("book-dock/finalize", token, selection)]);
    assert.equal(finalized.succeeded, 1);
    const result = finalized.results[0];
    assert.ok(result.bookId);
    assert.equal(simultaneous.succeeded, 1);
    assert.equal(simultaneous.results[0].bookId, result.bookId);
    const retried = await json("book-dock/finalize", token, selection);
    assert.equal(retried.results[0].bookId, result.bookId);
    assert.equal(retried.succeeded, 1);
    const receipt = await json(`uploads/${session.id}`, token);
    assert.equal(receipt.bookId, result.bookId);
    const book = await json(`books/${result.bookId}`, token);
    assert.equal(book.title, title);
    const delivered = await request(`books/files/${book.files[0].id}/serve`, token);
    assert.equal(delivered.status, 200);
    const actual = new Uint8Array(await delivered.arrayBuffer());
    assert.equal((await PDFDocument.load(actual)).getPageCount(), 1);
    assert.equal(actual.length, bytes.length);
    assert.equal((await request(`books/${result.bookId}`, other.accessToken)).status, 404);
    if (process.env.IPAD_E03_UPLOAD_RECEIPT_FILE)
      await writeFile(
        process.env.IPAD_E03_UPLOAD_RECEIPT_FILE,
        JSON.stringify({ bookId: book.id, fileId: book.files[0].id, title, username: process.env.IPAD_UPLOAD_USER ?? "ipad-editor" }),
      );
  } finally {
    for (const session of [owner, other]) await request("auth/logout", undefined, { refreshToken: session.refreshToken });
  }
});
