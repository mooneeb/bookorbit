import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { createWriteStream } from "node:fs";
import { mkdir, readFile, rm, writeFile } from "node:fs/promises";
import { createServer } from "node:http";
import { createRequire } from "node:module";
import { dirname, join } from "node:path";
import { DatabaseSync } from "node:sqlite";
import { promisify } from "node:util";

const require = createRequire(new URL("../../server/package.json", import.meta.url));
const { ZipArchive } = require("archiver");
const { PDFDocument, StandardFonts } = require("pdf-lib");
const sharp = require("sharp");
const mysql = require("mysql2/promise");
const execute = promisify(execFile);
const date = new Date("2025-01-01T00:00:00Z");
export const sourcePrefix = "/e03-source";
export const sourceCfi = "epubcfi(/6/2[chapter]!/4/2/1:5)";

async function zip(path, files) {
  const archive = new ZipArchive({ zlib: { level: 9 } });
  const destination = createWriteStream(path);
  const completed = new Promise((resolve, reject) => {
    destination.once("close", resolve);
    destination.once("error", reject);
    archive.once("error", reject);
  });
  archive.pipe(destination);
  for (const [name, bytes] of Object.entries(files)) archive.append(bytes, { name, date, store: name === "mimetype" });
  await Promise.all([archive.finalize(), completed]);
}

export async function createMigrationMediaFixtures(root) {
  const books = ["epub", "pdf", "cbz", "mp3"].map((format, index) => ({
    id: index + 1,
    format,
    title: `Migration ${format.toUpperCase()} proof`,
    folder: `proof-${format}`,
    filename: `proof.${format}`,
    relativePath: `proof-${format}/proof.${format}`,
    sourcePath: `${sourcePrefix}/proof-${format}/proof.${format}`,
    path: join(root, `proof-${format}`, `proof.${format}`),
  }));
  for (const book of books) await mkdir(dirname(book.path), { recursive: true });
  await zip(books[0].path, {
    mimetype: "application/epub+zip",
    "META-INF/container.xml":
      '<?xml version="1.0"?><container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" version="1.0"><rootfiles><rootfile full-path="OPS/package.opf" media-type="application/oebps-package+xml"/></rootfiles></container>',
    "OPS/package.opf":
      '<?xml version="1.0"?><package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="uid">urn:uuid:e03-migration-fixture</dc:identifier><dc:title>Migration EPUB proof</dc:title><dc:creator>Migration Author</dc:creator><dc:language>en</dc:language><meta property="dcterms:modified">2025-01-01T00:00:00Z</meta></metadata><manifest><item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/><item id="chapter" href="chapter.xhtml" media-type="application/xhtml+xml"/></manifest><spine><itemref id="chapter" idref="chapter"/></spine></package>',
    "OPS/nav.xhtml":
      '<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><head><title>Contents</title></head><body><nav epub:type="toc"><ol><li><a href="chapter.xhtml">Migration proof</a></li></ol></nav></body></html>',
    "OPS/chapter.xhtml":
      '<html xmlns="http://www.w3.org/1999/xhtml"><head><title>Migration proof</title></head><body><p id="passage">Migration source passage survives retry.</p></body></html>',
  });
  const pdf = await PDFDocument.create();
  pdf.setTitle(books[1].title);
  pdf.setAuthor("Migration Author");
  pdf.setCreationDate(date);
  pdf.setModificationDate(date);
  const font = await pdf.embedFont(StandardFonts.Helvetica);
  pdf.addPage([300, 400]).drawText("Migration PDF artifact proof", { x: 20, y: 350, font });
  await writeFile(books[1].path, await pdf.save());
  const image = await sharp({ create: { width: 320, height: 480, channels: 3, background: "#ffffff" } })
    .composite([
      {
        input: Buffer.from(
          '<svg width="320" height="480"><rect x="12" y="12" width="296" height="220" fill="#d0d0d0"/><text x="30" y="100" font-size="20">Migration comic proof</text></svg>',
        ),
      },
    ])
    .png()
    .toBuffer();
  await zip(books[2].path, {
    "001.png": image,
    "ComicInfo.xml": "<ComicInfo><Title>Migration CBZ proof</Title><Writer>Migration Author</Writer><PageCount>1</PageCount></ComicInfo>",
  });
  await execute(require("@ffmpeg-installer/ffmpeg").path, [
    "-hide_banner",
    "-loglevel",
    "error",
    "-f",
    "lavfi",
    "-i",
    "sine=frequency=440:sample_rate=8000:duration=8",
    "-ac",
    "1",
    "-b:a",
    "16k",
    "-metadata",
    `title=${books[3].title}`,
    "-metadata",
    `album=${books[3].title}`,
    "-metadata",
    "artist=Migration Author",
    "-y",
    books[3].path,
  ]);
  return books;
}

export async function addMigrationEbooks(root, books, total) {
  assert.ok(total >= books.length && total <= 1000);
  const archive = await require("unzipper").Open.buffer(await readFile(books[0].path));
  const files = Object.fromEntries(await Promise.all(archive.files.map(async (file) => [file.path, await file.buffer()])));
  while (books.length < total) {
    const id = books.length + 1;
    const folder = `proof-epub-${id}`;
    const path = join(root, folder, "proof.epub");
    await mkdir(dirname(path), { recursive: true });
    await zip(path, { ...files, "fixture-id.txt": `Migration ebook ${id}` });
    books.push({
      id,
      format: "epub",
      title: `Migration EPUB ${id} proof`,
      folder,
      filename: "proof.epub",
      relativePath: `${folder}/proof.epub`,
      sourcePath: `${sourcePrefix}/${folder}/proof.epub`,
      path,
    });
  }
  return books;
}

function absItem(book) {
  const metadata = { path: book.sourcePath, relPath: book.filename, filename: book.filename, ext: `.${book.format}` };
  return {
    id: `item-${book.id}`,
    libraryId: "library-1",
    mediaType: "book",
    path: `${sourcePrefix}/${book.folder}`,
    relPath: book.folder,
    media: {
      id: `book-${book.id}`,
      duration: book.format === "mp3" ? 8 : null,
      metadata: {
        title: `Imported ${book.title}`,
        authors: [{ id: "author-1", name: "Migration Author" }],
        language: "en",
        description: "Source metadata retained by migration",
        narrators: book.format === "mp3" ? ["Migration Narrator"] : [],
      },
      audioFiles: book.format === "mp3" ? [{ ino: String(book.id), index: 0, format: "mp3", duration: 8, metadata }] : [],
      ebookFile: book.format !== "mp3" ? { ino: String(book.id), ebookFormat: book.format, metadata } : null,
      tags: ["Migration fixture"],
    },
  };
}

function absProgress(book, userId = "source-user") {
  return {
    id: `progress-${book.id}`,
    userId,
    mediaItemId: `book-${book.id}`,
    libraryItemId: `item-${book.id}`,
    mediaItemType: "book",
    duration: book.format === "mp3" ? 8 : null,
    currentTime: book.format === "mp3" ? 4 : null,
    progress: 0.5,
    ebookLocation: book.format === "epub" ? sourceCfi : book.format === "mp3" ? null : "1",
    ebookProgress: book.format === "mp3" ? null : 0.5,
    isFinished: false,
    startedAt: "2025-01-01T00:00:00Z",
    createdAt: "2025-01-01T00:00:00Z",
    lastUpdate: 1735776000000,
    updatedAt: "2025-01-02T00:00:00Z",
  };
}

export async function startAudiobookshelfFixture(books, { bookmarkCount = 1, port = 0 } = {}) {
  assert.ok(Number.isInteger(bookmarkCount) && bookmarkCount > 0 && bookmarkCount <= 1000);
  assert.ok(Number.isInteger(port) && port >= 0 && port <= 65535);
  const bookmarks = Array.from({ length: bookmarkCount }, (_, index) => ({
    libraryItemId: "item-4",
    time: bookmarkCount === 1 ? 2 : (index + 1) / 100,
    title: bookmarkCount === 1 ? "Imported audio bookmark" : `Imported audio bookmark ${index + 1}`,
    createdAt: "2025-01-02T00:00:00Z",
  }));
  const requests = [];
  let failedBatchRequestsRemaining = 0;
  const items = books.map(absItem);
  const token = "E03-provider-fixture-token";
  const server = createServer(async (request, response) => {
    const url = new URL(request.url, "http://fixture");
    requests.push({ method: request.method, path: url.pathname, query: Object.fromEntries(url.searchParams) });
    response.setHeader("Content-Type", "application/json");
    const send = (body, status = 200) => {
      response.statusCode = status;
      response.end(JSON.stringify(body));
    };
    if (request.headers.authorization !== `Bearer ${token}`) return send({ error: "Unauthorized" }, 401);
    if (url.pathname === "/__fixture/fail-next-batch" && request.method === "POST") {
      failedBatchRequestsRemaining = 2;
      return send({ armed: true });
    }
    if (url.pathname === "/status") return send({ app: "audiobookshelf", serverVersion: "2.36.0", isInit: true });
    if (url.pathname === "/api/authorize" && request.method === "POST")
      return send({ user: { id: "admin", username: "fixture-admin", type: "root" } });
    if (url.pathname === "/api/users")
      return send({ users: [{ id: "source-user", username: "ipad-owner", email: "migration@example.test", isActive: true }] });
    if (url.pathname === "/api/users/source-user")
      return send({
        id: "source-user",
        username: "ipad-owner",
        isActive: true,
        mediaProgress: books.map((book) => absProgress(book)),
        bookmarks,
      });
    if (url.pathname === "/api/users/source-user/listening-sessions")
      return send({ sessions: [], total: 0, numPages: 1, page: Number(url.searchParams.get("page")) });
    if (url.pathname === "/api/libraries")
      return send({ libraries: [{ id: "library-1", mediaType: "book", folders: [{ id: "folder-1", path: sourcePrefix }] }] });
    if (url.pathname === "/api/libraries/library-1/items") {
      const limit = Number(url.searchParams.get("limit"));
      const page = Number(url.searchParams.get("page"));
      if (!Number.isInteger(limit) || limit < 1 || limit > 200) return send({ error: "Unbounded listing" }, 400);
      return send({
        results: items.slice(page * limit, (page + 1) * limit).map((item) => ({ id: item.id, mediaType: "book" })),
        total: items.length,
        page,
      });
    }
    if (url.pathname === "/api/items/batch/get" && request.method === "POST") {
      let body = "";
      for await (const chunk of request) body += chunk;
      const ids = JSON.parse(body).libraryItemIds;
      requests.at(-1).batchSize = ids.length;
      if (!ids.length || ids.length > 100) return send({ error: "Unbounded batch" }, 400);
      if (failedBatchRequestsRemaining > 0) {
        failedBatchRequestsRemaining--;
        return send({ error: "Controlled source interruption" }, 503);
      }
      return send({ libraryItems: items.filter((item) => ids.includes(item.id)) });
    }
    return send({ error: "Unexpected source request" }, 404);
  });
  await new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(port, "127.0.0.1", resolve);
  });
  return {
    connectionConfig: { mode: "api", baseUrl: `http://127.0.0.1:${server.address().port}`, apiToken: token, allowPrivateNetwork: true },
    sourceUserId: "source-user",
    control: { url: `http://127.0.0.1:${server.address().port}/__fixture/fail-next-batch`, token },
    requests,
    failNextBatch: () => {
      failedBatchRequestsRemaining = 1;
    },
    close: () => new Promise((resolve) => server.close(resolve)),
  };
}

export async function createAudiobookshelfBackup(root, books) {
  await mkdir(root, { recursive: true });
  const databasePath = join(root, "abs.sqlite");
  const database = new DatabaseSync(databasePath);
  try {
    database.exec(
      "CREATE TABLE users (id TEXT PRIMARY KEY, username TEXT, email TEXT, isActive INTEGER, bookmarks TEXT); CREATE TABLE libraryItems (id TEXT PRIMARY KEY, libraryId TEXT, libraryFolderId TEXT, path TEXT, relPath TEXT, mediaType TEXT, mediaId TEXT); CREATE TABLE books (id TEXT PRIMARY KEY, title TEXT, subtitle TEXT, publishedYear TEXT, publisher TEXT, description TEXT, isbn TEXT, asin TEXT, language TEXT, abridged INTEGER, duration REAL, narrators TEXT, audioFiles TEXT, ebookFile TEXT, tags TEXT, genres TEXT); CREATE TABLE mediaProgresses (id TEXT PRIMARY KEY, mediaItemId TEXT, mediaItemType TEXT, duration REAL, currentTime REAL, isFinished INTEGER, ebookLocation TEXT, ebookProgress REAL, finishedAt TEXT, extraData TEXT, userId TEXT, createdAt TEXT, updatedAt TEXT); CREATE TABLE libraryFolders (id TEXT PRIMARY KEY, libraryId TEXT, path TEXT); CREATE TABLE authors (id TEXT PRIMARY KEY, name TEXT, lastFirst TEXT, description TEXT); CREATE TABLE bookAuthors (id TEXT PRIMARY KEY, bookId TEXT, authorId TEXT, createdAt TEXT);",
    );
    database
      .prepare("INSERT INTO users VALUES (?, ?, ?, ?, ?)")
      .run(
        "source-user",
        "ipad-owner",
        "migration@example.test",
        1,
        JSON.stringify([{ libraryItemId: "item-4", time: 2, title: "Imported audio bookmark", createdAt: "2025-01-02T00:00:00Z" }]),
      );
    database.prepare("INSERT INTO libraryFolders VALUES (?, ?, ?)").run("folder-1", "library-1", sourcePrefix);
    database.prepare("INSERT INTO authors VALUES (?, ?, ?, ?)").run("author-1", "Migration Author", "Author, Migration", null);
    for (const book of books) {
      const item = absItem(book);
      const progress = absProgress(book);
      database
        .prepare("INSERT INTO libraryItems VALUES (?, ?, ?, ?, ?, ?, ?)")
        .run(item.id, "library-1", "folder-1", item.path, item.relPath, "book", item.media.id);
      database
        .prepare("INSERT INTO books VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)")
        .run(
          item.media.id,
          item.media.metadata.title,
          null,
          "2025",
          "Fixture Publisher",
          "Source metadata retained by migration",
          null,
          null,
          "en",
          0,
          item.media.duration,
          JSON.stringify(item.media.metadata.narrators),
          JSON.stringify(item.media.audioFiles),
          JSON.stringify(item.media.ebookFile),
          JSON.stringify(item.media.tags),
          "[]",
        );
      database.prepare("INSERT INTO bookAuthors VALUES (?, ?, ?, ?)").run(`link-${book.id}`, item.media.id, "author-1", "2025-01-01");
      database
        .prepare("INSERT INTO mediaProgresses VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)")
        .run(
          progress.id,
          progress.mediaItemId,
          "book",
          progress.duration,
          progress.currentTime,
          0,
          progress.ebookLocation,
          progress.ebookProgress,
          null,
          JSON.stringify({ libraryItemId: item.id, progress: 0.5 }),
          "source-user",
          progress.createdAt,
          progress.updatedAt,
        );
    }
  } finally {
    database.close();
  }
  const backupPath = join(root, "fixture.audiobookshelf");
  await zip(backupPath, { details: "2025-01-01T0000\nsqlite\n1735689600000\n2.36.0", "absdatabase.sqlite": await readFile(databasePath) });
  await rm(databasePath);
  return { connectionConfig: { mode: "backup", backupPath }, sourceUserId: "source-user", close: async () => {} };
}

export async function createCalibreSnapshot(root, books) {
  await mkdir(root, { recursive: true });
  const appDatabasePath = join(root, "app.db");
  const metadataDatabasePath = join(root, "metadata.db");
  const schemaRoot = new URL("../../server/src/modules/migration/adapters/calibre-web-automated/test-fixtures/", import.meta.url);
  const app = new DatabaseSync(appDatabasePath);
  const metadata = new DatabaseSync(metadataDatabasePath);
  try {
    app.exec(await readFile(new URL("cwa-v4.0.6-app-schema.sql", schemaRoot), "utf8"));
    metadata.exec(await readFile(new URL("cwa-v4.0.6-metadata-schema.sql", schemaRoot), "utf8"));
    app
      .prepare("INSERT INTO user (id,name,email,role,password,locale,sidebar_view) VALUES (1,?,?,?,?,?,?)")
      .run("ipad-owner", "migration@example.test", 1, "fixture-password", "en", 1);
    app.prepare("INSERT INTO settings (id,config_calibre_dir) VALUES (1,?)").run(sourcePrefix);
    metadata.prepare("INSERT INTO authors (id,name,sort,link) VALUES (1,?,?,?)").run("Migration Author", "Author, Migration", "");
    for (const book of books) {
      metadata
        .prepare("INSERT INTO books (id,title,sort,pubdate,series_index,author_sort,path,uuid) VALUES (?,?,?,?,?,?,?,?)")
        .run(book.id, `Imported ${book.title}`, book.title, "2025-01-01T00:00:00Z", 1, "Author, Migration", book.folder, `fixture-${book.id}`);
      metadata
        .prepare("INSERT INTO data (id,book,format,uncompressed_size,name) VALUES (?,?,?,?,?)")
        .run(book.id, book.id, book.format.toUpperCase(), (await readFile(book.path)).length, "proof");
      metadata.prepare("INSERT INTO books_authors_link (id,book,author) VALUES (?,?,1)").run(book.id, book.id);
      app
        .prepare(
          "INSERT INTO book_read_link (id,book_id,user_id,read_status,last_modified,last_time_started_reading,times_started_reading) VALUES (?,?,1,2,?,?,1)",
        )
        .run(book.id, book.id, "2025-01-02T00:00:00Z", "2025-01-01T00:00:00Z");
      app
        .prepare("INSERT INTO bookmark (id,user_id,book_id,format,bookmark_key) VALUES (?,1,?,?,?)")
        .run(book.id, book.id, book.format.toUpperCase(), book.format === "epub" ? sourceCfi : book.format === "mp3" ? "4000" : "1");
    }
  } finally {
    app.close();
    metadata.close();
  }
  return { connectionConfig: { mode: "snapshot", appDatabasePath, metadataDatabasePath }, sourceUserId: "1", close: async () => {} };
}

export async function createBookloreFixture(books, databaseName) {
  assert.match(databaseName, /^e03_[a-z0-9_]+$/);
  const credentials = { host: "127.0.0.1", port: Number(process.env.IPAD_MIGRATION_MYSQL_PORT ?? 16306), user: "root", password: "E03SourceFixture" };
  const admin = await mysql.createConnection(credentials);
  await admin.execute(`CREATE DATABASE \`${databaseName}\``);
  await admin.end();
  const connection = await mysql.createConnection({ ...credentials, database: databaseName });
  try {
    for (const statement of [
      "CREATE TABLE users (id INT PRIMARY KEY, username VARCHAR(100), name VARCHAR(255), email VARCHAR(255))",
      "CREATE TABLE library_path (id INT PRIMARY KEY, path VARCHAR(1024))",
      "CREATE TABLE book (id INT PRIMARY KEY, library_path_id INT, deleted TINYINT DEFAULT 0)",
      "CREATE TABLE book_metadata (book_id INT PRIMARY KEY, title VARCHAR(255), author TEXT, description TEXT, language VARCHAR(40), duration_seconds INT)",
      "CREATE TABLE book_file (id INT PRIMARY KEY, book_id INT, absolute_path VARCHAR(1024), file_name VARCHAR(255), file_sub_path VARCHAR(1024), current_hash VARCHAR(64), duration_seconds INT, is_book TINYINT DEFAULT 1)",
      "CREATE TABLE user_book_progress (user_id INT, book_id INT, status VARCHAR(50), percentage DECIMAL(8,2), started_at DATETIME, finished_at DATETIME, updated_at DATETIME)",
      "CREATE TABLE user_book_file_progress (user_id INT, book_id INT, book_file_id INT, percentage DECIMAL(8,2), cfi VARCHAR(2000), page_number INT, position_seconds DECIMAL(10,2), updated_at DATETIME)",
      "CREATE TABLE annotations (user_id INT, book_id INT, cfi VARCHAR(2000), text TEXT, color VARCHAR(20), style VARCHAR(20), note TEXT, chapter_title VARCHAR(255), created_at DATETIME, updated_at DATETIME)",
    ])
      await connection.execute(statement);
    await connection.execute("INSERT INTO users VALUES (1,?,?,?)", ["ipad-owner", "Migration owner", "migration@example.test"]);
    await connection.execute("INSERT INTO library_path VALUES (1,?)", [sourcePrefix]);
    for (const book of books) {
      await connection.execute("INSERT INTO book VALUES (?,1,0)", [book.id]);
      await connection.execute("INSERT INTO book_metadata VALUES (?,?,?,?,?,?)", [
        book.id,
        `Imported ${book.title}`,
        "Migration Author",
        "Source metadata retained by migration",
        "en",
        book.format === "mp3" ? 8 : null,
      ]);
      await connection.execute("INSERT INTO book_file VALUES (?,?,?,?,?,?,?,1)", [
        book.id,
        book.id,
        book.sourcePath,
        book.filename,
        book.folder,
        null,
        book.format === "mp3" ? 8 : null,
      ]);
      await connection.execute("INSERT INTO user_book_progress VALUES (1,?,'reading',50,'2025-01-01',NULL,'2025-01-02')", [book.id]);
      await connection.execute("INSERT INTO user_book_file_progress VALUES (1,?,?,50,?,?,?,'2025-01-02')", [
        book.id,
        book.id,
        book.format === "epub" ? sourceCfi : null,
        ["pdf", "cbz"].includes(book.format) ? 1 : null,
        book.format === "mp3" ? 4 : null,
      ]);
    }
    await connection.execute(
      "INSERT INTO annotations VALUES (1,1,?,'Migration source passage','yellow','highlight','Imported permitted passage note','Migration proof','2025-01-01','2025-01-02')",
      [sourceCfi],
    );
  } finally {
    await connection.end();
  }
  return {
    connectionConfig: { ...credentials, database: databaseName, ssl: false },
    sourceUserId: "1",
    close: async () => {
      await removeBookloreFixture({ ...credentials, database: databaseName });
    },
  };
}

export async function removeBookloreFixture(config) {
  assert.match(config.database, /^e03_[a-z0-9_]+$/);
  assert.equal(config.host, "127.0.0.1");
  const { database, ...credentials } = config;
  const connection = await mysql.createConnection(credentials);
  try {
    await connection.execute(`DROP DATABASE IF EXISTS \`${database}\``);
  } finally {
    await connection.end();
  }
}
