import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { createRequire } from "node:module";
import { mkdir, readFile, stat, writeFile } from "node:fs/promises";
import { dirname, join, relative } from "node:path";
import { test } from "node:test";

const require = createRequire(new URL("../../server/package.json", import.meta.url));
const { Client } = require("pg");
const { PDFDocument, PDFName } = require("pdf-lib");
const base = process.env.IPAD_E03_API_URL ?? "http://localhost:16482/api/v1";
async function request(path, token, body, method = body ? "POST" : "GET", signal) {
  return fetch(`${base}/${path}`, {
    method,
    signal,
    headers: { ...(token ? { Authorization: `Bearer ${token}` } : {}), ...(body ? { "Content-Type": "application/json" } : {}) },
    body: body ? JSON.stringify(body) : undefined,
  });
}
async function json(path, token, body, method) {
  const response = await request(path, token, body, method);
  assert.ok(response.ok, `${path}: ${response.status} ${await response.clone().text()}`);
  const content = await response.text();
  return content ? JSON.parse(content) : undefined;
}
async function login(username) {
  return json("auth/login", null, {
    username,
    password: process.env.IPAD_FIXTURE_PASSWORD ?? "IpadFixture123",
    clientKind: "native",
    deviceLabel: "Rename HTTP proof",
  });
}
function events(text) {
  return text
    .split("\n")
    .filter((line) => line.startsWith("data: "))
    .map((line) => JSON.parse(line.slice(6)));
}

test("IPAD-E03-A05-rename: bounded cross-batch review and interrupted retry retain files, reading state, and source PDF ink", async () => {
  const owner = await login("ipad-owner");
  const reader = await login("ipad-reader");
  const token = owner.accessToken;
  const existing = (await json("libraries", token)).find((library) => library.type === "books");
  const detail = await json(`libraries/${existing.id}`, token);
  const directory = join(dirname(detail.folders[0].path), `rename-proof-${randomUUID()}`);
  await mkdir(directory, { recursive: true });
  const library = await json("libraries", token, {
    name: `Rename proof ${randomUUID()}`,
    icon: "book",
    folders: [directory],
    watch: false,
    fileRenameEnabled: true,
    fileNamingPattern: "{title}",
    organizationMode: "book_per_file",
  });
  const fullLibrary = await json(`libraries/${library.id}`, token);
  const folderId = fullLibrary.folders[0].id;
  const pdf = await PDFDocument.create();
  const page = pdf.addPage([300, 400]);
  const ink = pdf.context.register(
    pdf.context.obj({ Type: "Annot", Subtype: "Ink", Rect: [10, 10, 100, 100], InkList: [[10, 10, 30, 30]], Contents: "Retained PDF ink" }),
  );
  page.node.set(PDFName.of("Annots"), pdf.context.obj([ink]));
  const sourceBytes = Buffer.from(await pdf.save());
  const client = new Client({ connectionString: process.env.DATABASE_URL });
  await client.connect();
  const records = [];
  try {
    await client.query("BEGIN");
    for (let index = 0; index < 252; index++) {
      const path = join(directory, `source-${index}.pdf`);
      await writeFile(path, sourceBytes);
      const info = await stat(path);
      const title = index === 0 || index === 251 ? "Shared target" : index === 102 ? "SOURCE-102" : `Book ${index}`;
      const {
        rows: [book],
      } = await client.query("insert into books (library_id,library_folder_id,folder_path) values ($1,$2,$3) returning id", [
        library.id,
        folderId,
        path,
      ]);
      const {
        rows: [file],
      } = await client.query(
        "insert into book_files (book_id,library_folder_id,absolute_path,rel_path,ino,size_bytes,mtime,format) values ($1,$2,$3,$4,$5,$6,$7,'pdf') returning id",
        [book.id, folderId, path, relative(directory, path), info.ino, info.size, info.mtime],
      );
      await client.query("update books set primary_file_id=$1 where id=$2", [file.id, book.id]);
      await client.query("insert into book_metadata (book_id,title) values ($1,$2)", [book.id, title]);
      records.push({ bookId: book.id, fileId: file.id, path, title });
    }
    await client.query("COMMIT");
  } catch (error) {
    await client.query("ROLLBACK");
    throw error;
  } finally {
    await client.end();
  }
  const chosen = records[100];
  await json(`books/files/${chosen.fileId}/progress`, token, { source: "text", percentage: 45, pageNumber: 1 });
  await json(`books/${chosen.bookId}/personal-note`, token, { note: "Rename retains the reader's private note" }, "PATCH");
  const rect = { x: 0.1, y: 0.1, width: 0.2, height: 0.1 };
  await json(`books/${chosen.bookId}/annotations`, token, {
    bookFileId: chosen.fileId,
    pdf: { page: 0, rect, rects: [rect] },
    text: "Preserved passage",
    note: "Passage note survives rename",
  });
  const before = await json(`books/${chosen.bookId}`, token);
  const progress = await json(`books/files/${chosen.fileId}/progress`, token);
  const annotations = await json(`books/${chosen.bookId}/annotations?page=1&pageSize=100`, token);
  const previewPath = `libraries/${library.id}/bulk-rename/preview`;
  const first = await json(`${previewPath}?page=1&pageSize=200`, token);
  assert.equal(first.items.length, 200);
  assert.equal(first.total, 252);
  assert.equal(first.totalByStatus.collision, 2, "A collision across candidate batch boundaries holds both books back");
  assert.equal(first.totalByStatus.will_rename, 250);
  assert.equal((await json(`${previewPath}?page=2&pageSize=200`, token)).items.length, 52);
  assert.equal((await json(`${previewPath}?search=Book%20100&pageSize=10`, token)).items[0].bookId, chosen.bookId);
  assert.deepEqual(await readFile(chosen.path), sourceBytes, "Preview never modifies files");
  assert.equal((await request(`${previewPath}?pageSize=50000`, token)).status, 400);
  assert.equal((await request(`libraries/${library.id}/bulk-rename/execute`, reader.accessToken, {})).status, 403);
  assert.equal((await request(`libraries/${library.id}/bulk-rename/execute`, null, {})).status, 401);
  const conflict = records[101];
  const conflictingBytes = Buffer.from("Newer target must not be overwritten");
  await writeFile(join(directory, `${conflict.title}.pdf`), conflictingBytes);
  const abort = new AbortController();
  const response = await request(`libraries/${library.id}/bulk-rename/execute`, token, {}, "POST", abort.signal);
  assert.equal(response.status, 200);
  const stream = response.body.getReader();
  let received = "";
  while (true) {
    const { value, done } = await stream.read();
    if (done) break;
    received += new TextDecoder().decode(value);
    if (received.includes('"bookId"')) {
      abort.abort();
      break;
    }
  }
  const deadline = Date.now() + 10000;
  while ((await json(`libraries/${library.id}/bulk-rename/status`, token)).running && Date.now() < deadline)
    await new Promise((resolve) => setTimeout(resolve, 50));
  assert.equal((await json(`libraries/${library.id}/bulk-rename/status`, token)).running, false);
  const retry = await request(`libraries/${library.id}/bulk-rename/execute`, token, {});
  assert.equal(retry.status, 200);
  assert.ok(events(await retry.text()).find((event) => event.done));
  const after = await json(`books/${chosen.bookId}`, token);
  assert.equal(after.personalNote, before.personalNote);
  assert.deepEqual(
    after.files.map((file) => file.id),
    before.files.map((file) => file.id),
  );
  assert.deepEqual(await json(`books/files/${chosen.fileId}/progress`, token), progress);
  assert.deepEqual(await json(`books/${chosen.bookId}/annotations?page=1&pageSize=100`, token), annotations);
  const caseOnly = await request(`books/files/${records[102].fileId}/serve`, token);
  assert.equal(caseOnly.status, 200);
  assert.deepEqual(Buffer.from(await caseOnly.arrayBuffer()), sourceBytes, "Case-only renames preserve their source file");
  const served = await request(`books/files/${chosen.fileId}/serve`, token);
  assert.equal(served.status, 200);
  assert.deepEqual(Buffer.from(await served.arrayBuffer()), sourceBytes, "Source PDF ink and every original byte survive cancel and retry");
  assert.deepEqual(await readFile(join(directory, `${conflict.title}.pdf`)), conflictingBytes);
  assert.deepEqual(await readFile(conflict.path), sourceBytes);
  assert.deepEqual(await readFile(records[0].path), sourceBytes);
  assert.deepEqual(await readFile(records[251].path), sourceBytes);
  const remaining = await json(`${previewPath}?status=will_rename&pageSize=200`, token);
  assert.equal(remaining.total, 1, "Only the protected external target remains unrenamed");
});
