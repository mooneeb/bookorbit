import assert from "node:assert/strict";
import { createRequire } from "node:module";
import { test } from "node:test";

const require = createRequire(new URL("../../server/package.json", import.meta.url));
const { Client } = require("pg");
const base = process.env.IPAD_API_BASE ?? "http://localhost:16482/api/v1";
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

test(
  "IPAD-E03-A05-entity-mutation-bounds: 50000-book merge and split preserve private reading data and reject foreign or stale entities",
  { timeout: 120000 },
  async () => {
    const db = new Client({ connectionString: process.env.E2E_DATABASE_URL ?? process.env.DATABASE_URL });
    await db.connect();
    const session = await json("auth/login", undefined, {
      username: "ipad-editor",
      password: "IpadFixture123",
      clientKind: "native",
      deviceLabel: "Entity mutation bounds",
    });
    const token = session.accessToken;
    const bookId = Number(process.env.IPAD_ENTITY_BOOK_ID ?? "1");
    const marker = `EntityMutation-${crypto.randomUUID()}`;
    const before = await json(`books/${bookId}`, token);
    const fileId = before.files[0].id;
    const bytes = Buffer.from(await (await request(`books/files/${fileId}/serve`, token)).arrayBuffer());
    const progress = await json(`books/files/${fileId}/progress`, token);
    const annotations = await json(`books/${bookId}/annotations?page=1&pageSize=100`, token);
    let privateLibrary;
    try {
      const fixture = (await db.query("SELECT library_id,library_folder_id FROM books WHERE id=$1", [bookId])).rows[0];
      const source = (await db.query("INSERT INTO genres(name) VALUES ($1) RETURNING id", [`${marker} source`])).rows[0].id;
      const target = (await db.query("INSERT INTO genres(name) VALUES ($1) RETURNING id", [`${marker} target`])).rows[0].id;
      await db.query("INSERT INTO books(library_id,library_folder_id,folder_path) SELECT $1,$2,$3 || '/' || n FROM generate_series(1,49999) n", [
        fixture.library_id,
        fixture.library_folder_id,
        marker,
      ]);
      await db.query("INSERT INTO book_metadata(book_id,title) SELECT id,$1 FROM books WHERE folder_path LIKE $2", [`${marker} book`, `${marker}/%`]);
      await db.query("INSERT INTO book_genres(book_id,genre_id) SELECT id,$1 FROM books WHERE folder_path LIKE $2", [source, `${marker}/%`]);
      await json(`books/${bookId}/metadata`, token, { genres: [`${marker} source`] }, "PATCH");
      await json(`books/${bookId}/personal-note`, token, { note: `${marker} private note` }, "PATCH");
      privateLibrary = (await db.query("INSERT INTO libraries(name) VALUES ($1) RETURNING id", [`${marker} foreign`])).rows[0].id;
      const privateFolder = (
        await db.query("INSERT INTO library_folders(library_id,path) VALUES ($1,$2) RETURNING id", [privateLibrary, `${marker}/foreign`])
      ).rows[0].id;
      const foreignBook = (
        await db.query("INSERT INTO books(library_id,library_folder_id,folder_path) VALUES ($1,$2,$3) RETURNING id", [
          privateLibrary,
          privateFolder,
          `${marker}/foreign/book`,
        ])
      ).rows[0].id;
      await db.query("INSERT INTO book_metadata(book_id,title) VALUES ($1,$2)", [foreignBook, `${marker} foreign book`]);
      await db.query("INSERT INTO book_genres(book_id,genre_id) VALUES ($1,$2)", [foreignBook, source]);
      const body = { targetEntityId: target, sourceEntityIds: [source], writeFiles: false };
      const preview = await json(`entity-manager/genre/info?entityId=${source}`, token);
      assert.equal(preview.bookCount, 50000);
      assert.ok(preview.bookTitles.length <= 5);
      assert.equal((await request("entity-manager/genre/merge", token, body)).status, 403);
      assert.deepEqual(await json(`entity-manager/genre/info?entityId=${source}`, token), preview);
      await db.query("DELETE FROM book_genres WHERE book_id=$1", [foreignBook]);
      const startedAt = Date.now();
      const merged = await json("entity-manager/genre/merge", token, body);
      assert.equal(merged.affectedBookCount, 50000);
      assert.ok(Date.now() - startedAt < 30000, "A 50000-book relation mutation must finish within 30 seconds");
      assert.equal((await json(`entity-manager/genre/info?entityId=${target}`, token)).bookCount, 50000);
      assert.equal((await request("entity-manager/genre/merge", token, body)).status, 404);
      assert.deepEqual((await json(`books/${bookId}`, token)).genres, [`${marker} target`]);
      const split = await json("entity-manager/genre/split", token, {
        entityId: target,
        newNames: [`${marker} split A`, `${marker} split B`],
        writeFiles: false,
      });
      assert.equal(split.affectedBookCount, 50000);
      for (const entity of split.newEntities) assert.equal((await json(`entity-manager/genre/info?entityId=${entity.id}`, token)).bookCount, 50000);
      assert.equal((await request(`entity-manager/genre/info?entityId=${target}`, token)).status, 404);
      const after = await json(`books/${bookId}`, token);
      assert.deepEqual(after.files, before.files);
      assert.equal(after.personalNote, `${marker} private note`);
      assert.deepEqual(await json(`books/files/${fileId}/progress`, token), progress);
      assert.deepEqual(await json(`books/${bookId}/annotations?page=1&pageSize=100`, token), annotations);
      assert.deepEqual(Buffer.from(await (await request(`books/files/${fileId}/serve`, token)).arrayBuffer()), bytes);
    } finally {
      await json(`books/${bookId}/metadata`, token, { genres: before.genres ?? [] }, "PATCH");
      await json(`books/${bookId}/personal-note`, token, { note: before.personalNote }, "PATCH");
      await db.query("DELETE FROM books WHERE folder_path LIKE $1", [`${marker}/%`]);
      await db.query("DELETE FROM genres WHERE name LIKE $1", [`${marker}%`]);
      if (privateLibrary) await db.query("DELETE FROM libraries WHERE id=$1", [privateLibrary]);
      await json("auth/logout", undefined, { refreshToken: session.refreshToken });
      await db.end();
    }
  },
);
