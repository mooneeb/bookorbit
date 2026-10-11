import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFile, writeFile } from "node:fs/promises";
import { createRequire } from "node:module";
import { dirname, isAbsolute, join, relative } from "node:path";

const require = createRequire(new URL("../../server/package.json", import.meta.url));
const { Client } = require("pg");
const fixturePath = process.env.IPAD_MERGE_FIXTURE;
const probePath = process.env.IPAD_MERGE_RESUME_PROBE;
assert.ok(fixturePath && probePath && process.env.IPAD_DATABASE_URL, "Explicit isolated fixture paths and database are required");
const fixture = JSON.parse(await readFile(fixturePath, "utf8"));
const probe = JSON.parse(await readFile(probePath, "utf8"));
const parent = dirname(dirname(probe.newPath));
assert.match(parent, /\/e03-http-merge-final-\d+$/);
assert.equal(probe.keeperBookId, fixture.targetBookId);
const knownPairs = [fixture, fixture.preservation, fixture.audioConflict];
const bookIds = knownPairs.flatMap((pair) => [pair.sourceBookId, pair.targetBookId]);
const fileIds = knownPairs.flatMap((pair) =>
  [pair.sourceFileId, pair.targetFileId, pair.sourceAudioFileId, pair.targetAudioFileId].filter(Number.isInteger),
);
const base = process.env.IPAD_API_BASE ?? "http://localhost:16482/api/v1";
const client = new Client({ connectionString: process.env.IPAD_DATABASE_URL });
await client.connect();

function contains(path) {
  const child = relative(parent, path);
  return !isAbsolute(child) && child !== ".." && !child.startsWith("../");
}

function digest(value) {
  return createHash("sha256")
    .update(typeof value === "string" || Buffer.isBuffer(value) ? value : JSON.stringify(value))
    .digest("hex");
}

async function json(path, token, body, method = body ? "POST" : "GET") {
  const response = await fetch(`${base}/${path}`, {
    method,
    headers: { ...(token ? { Authorization: `Bearer ${token}` } : {}), ...(body ? { "Content-Type": "application/json" } : {}) },
    body: body ? JSON.stringify(body) : undefined,
  });
  assert.ok(response.ok, `${path}: ${response.status} ${await response.clone().text()}`);
  const text = await response.text();
  return text ? JSON.parse(text) : undefined;
}

async function snapshot() {
  const books = (await client.query("select * from books where id=any($1::int[]) order by id", [bookIds])).rows;
  const files = (await client.query("select * from book_files where book_id=any($1::int[]) order by id", [bookIds])).rows;
  const receipts = (
    await client.query("select * from audit_log where action='book.duplicate_merge' and resource_id=any($1::int[]) order by id", [bookIds])
  ).rows;
  const outsideBooks = (
    await client.query("select * from books where library_id=$1 and id<>all($2::int[]) order by id limit 201", [fixture.libraryId, bookIds])
  ).rows;
  const outsideFiles = (
    await client.query(
      "select f.* from book_files f join books b on b.id=f.book_id where b.library_id=$1 and b.id<>all($2::int[]) order by f.id limit 201",
      [fixture.libraryId, bookIds],
    )
  ).rows;
  assert.ok(outsideBooks.length <= 200 && outsideFiles.length <= 200);
  const protectedState = {};
  const tables = [
    "annotations",
    "bookmarks",
    "reading_sessions",
    "user_book_notes",
    "user_book_status",
    "kobo_book_entitlements",
    "kobo_reading_states",
    "kobo_device_snapshot_books",
    "kobo_snapshot_books",
  ];
  for (const table of tables) {
    const rows = (
      await client.query(`select to_jsonb(t) row from ${table} t where book_id=any($1::int[]) order by to_jsonb(t)::text limit 1001`, [bookIds])
    ).rows;
    assert.ok(rows.length <= 1000);
    protectedState[table] = { count: rows.length, sha256: digest(rows) };
  }
  for (const [table, where] of [
    ["reading_progress", "book_file_id=any($1::int[])"],
    ["annotation_positions", "annotation_id in (select id from annotations where book_id=any($1::int[]))"],
  ]) {
    const rows = (
      await client.query(`select to_jsonb(t) row from ${table} t where ${where} order by to_jsonb(t)::text limit 1001`, [
        table === "reading_progress" ? fileIds : bookIds,
      ])
    ).rows;
    assert.ok(rows.length <= 1000);
    protectedState[table] = { count: rows.length, sha256: digest(rows) };
  }
  const bytes = await Promise.all(
    files.map(async (file) => ({ fileId: file.id, path: file.absolute_path, sha256: digest(await readFile(file.absolute_path)) })),
  );
  return {
    books,
    files,
    receipts,
    protectedState,
    bytes,
    outsideBooks: { count: outsideBooks.length, sha256: digest(outsideBooks) },
    outsideFiles: { count: outsideFiles.length, sha256: digest(outsideFiles) },
  };
}

let session;
let committed = false;
try {
  session = await json("auth/login", undefined, {
    username: "ipad-owner",
    password: "IpadFixture123",
    clientKind: "native",
    deviceLabel: "E03 merge fixture root alignment",
  });
  const libraryBefore = await json(`libraries/${fixture.libraryId}`, session.accessToken);
  const ownership = (
    await client.query(
      "select u.id user_id,u.username,u.is_superuser,a.access_level from users u left join user_library_access a on a.user_id=u.id and a.library_id=$1 where u.username='ipad-owner'",
      [fixture.libraryId],
    )
  ).rows;
  assert.equal(ownership.length, 1);
  assert.ok(ownership[0].is_superuser || ownership[0].access_level === "editor");
  assert.equal(libraryBefore.watch, false);
  assert.equal(libraryBefore.autoScanCronExpression, null);
  const { progress } = await json(`scanner/libraries/${fixture.libraryId}/scan-status`, session.accessToken);
  assert.notEqual(progress?.status, "running");
  await client.query("begin");
  await client.query("set local lock_timeout='5s'");
  await client.query("set local statement_timeout='30s'");
  const before = await snapshot();
  assert.deepEqual(
    before.books.map((book) => book.id),
    [fixture.targetBookId, fixture.preservation.targetBookId, fixture.audioConflict.sourceBookId, fixture.audioConflict.targetBookId].sort(
      (a, b) => a - b,
    ),
  );
  assert.ok(before.books.every((book) => book.library_id === fixture.libraryId && contains(book.folder_path)));
  assert.ok(before.files.every((file) => fileIds.includes(file.id) && contains(file.absolute_path)));
  assert.equal(before.receipts.length, 2);
  assert.ok(
    before.receipts.every(
      (row) => row.meta.libraryId === fixture.libraryId && contains(row.meta.sourceFolderPath) && contains(row.meta.targetFolderPath),
    ),
  );
  const {
    rows: [folder],
  } = await client.query("insert into library_folders(library_id,path,role) values($1,$2,'downloads') returning id,library_id,path,role", [
    fixture.libraryId,
    parent,
  ]);
  assert.ok(folder && folder.id !== fixture.libraryFolderId);
  const changedBooks = (
    await client.query(
      "update books set library_folder_id=$1 where id=any($2::int[]) and library_id=$3 and left(folder_path,length($4)+1)=$4||'/' returning id",
      [folder.id, before.books.map((book) => book.id), fixture.libraryId, parent],
    )
  ).rows
    .map((row) => row.id)
    .sort((a, b) => a - b);
  assert.deepEqual(
    changedBooks,
    before.books.map((book) => book.id),
  );
  const changedFiles = [];
  for (const file of before.files) {
    const result = await client.query(
      "update book_files set rel_path=$1 where id=$2 and book_id=any($3::int[]) and library_folder_id=$4 and absolute_path=$5 returning id",
      [relative(parent, file.absolute_path), file.id, changedBooks, folder.id, file.absolute_path],
    );
    assert.equal(result.rowCount, 1);
    changedFiles.push(file.id);
  }
  const changedReceipts = (
    await client.query(
      "update audit_log set meta=jsonb_set(meta,'{libraryFolderId}',to_jsonb($1::int)) where id=any($2::bigint[]) and action='book.duplicate_merge' and resource_id=any($3::int[]) and meta->>'libraryId'=$4 and left(meta->>'sourceFolderPath',length($5)+1)=$5||'/' and left(meta->>'targetFolderPath',length($5)+1)=$5||'/' returning id",
      [folder.id, before.receipts.map((row) => row.id), bookIds, String(fixture.libraryId), parent],
    )
  ).rows.map((row) => row.id);
  assert.equal(changedReceipts.length, before.receipts.length);
  const after = await snapshot();
  assert.deepEqual(after.protectedState, before.protectedState);
  assert.deepEqual(after.bytes, before.bytes);
  assert.deepEqual(after.outsideBooks, before.outsideBooks);
  assert.deepEqual(after.outsideFiles, before.outsideFiles);
  for (let index = 0; index < before.books.length; index++)
    assert.deepEqual(after.books[index], { ...before.books[index], library_folder_id: folder.id });
  for (let index = 0; index < before.files.length; index++)
    assert.deepEqual(after.files[index], {
      ...before.files[index],
      library_folder_id: folder.id,
      rel_path: relative(parent, before.files[index].absolute_path),
    });
  for (let index = 0; index < before.receipts.length; index++)
    assert.deepEqual(after.receipts[index], { ...before.receipts[index], meta: { ...before.receipts[index].meta, libraryFolderId: folder.id } });
  await client.query("commit");
  committed = true;
  for (const pair of knownPairs) pair.libraryFolderId = folder.id;
  await writeFile(fixturePath, JSON.stringify(fixture, null, 2));
  const libraryAfter = await json(`libraries/${fixture.libraryId}`, session.accessToken);
  const settings = ({ folders, ...values }) => values;
  assert.deepEqual(settings(libraryAfter), settings(libraryBefore));
  assert.deepEqual(
    libraryAfter.folders.filter((item) => item.id !== folder.id),
    libraryBefore.folders,
  );
  assert.ok(libraryAfter.folders.some((item) => item.id === folder.id && item.path === parent));
  const ledger = {
    parent,
    libraryId: fixture.libraryId,
    originalFolderId: libraryBefore.folders[0].id,
    newFolderId: folder.id,
    ownership,
    changedBookIds: changedBooks,
    changedFileIds: changedFiles,
    changedReceiptIds: changedReceipts,
    libraryBefore,
    libraryAfter,
    before,
    after,
  };
  await writeFile(join(dirname(probePath), "merge-fixture-attribution-ledger.json"), JSON.stringify(ledger, null, 2));
  console.log(
    JSON.stringify({
      parent,
      libraryId: fixture.libraryId,
      newFolderId: folder.id,
      changedBookIds: changedBooks,
      changedFileIds: changedFiles,
      changedReceiptIds: changedReceipts,
      protectedStateUnchanged: true,
      bytesUnchanged: true,
      outsideRowsUnchanged: true,
      settingsUnchanged: true,
    }),
  );
} finally {
  if (!committed) await client.query("rollback");
  if (session) await json("auth/logout", undefined, { refreshToken: session.refreshToken });
  await client.end();
}
