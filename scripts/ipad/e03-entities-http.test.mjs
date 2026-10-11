import assert from "node:assert/strict";
import { test } from "node:test";

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
async function login(username) {
  return json("auth/login", undefined, { username, password: "IpadFixture123", clientKind: "native", deviceLabel: "E03 entity HTTP" });
}

test("IPAD-E03-A05-entities-guards: malformed mutations and self merge cannot change a library", async () => {
  const session = await login("ipad-editor");
  const restricted = await login("ipad-restricted");
  try {
    const token = session.accessToken;
    const page = await json("entity-manager/author/browse?page=1&pageSize=1", token);
    assert.equal(page.items.length, 1);
    const id = page.items[0].id;
    const before = await json(`entity-manager/author/info/${id}`, token);
    for (const [operation, body] of [
      ["merge", { targetEntityId: id, sourceEntityIds: [id] }],
      ["merge", { targetEntityId: id, sourceEntityIds: [] }],
      ["merge", {}],
      ["rename", { entityId: id, newName: " " }],
      ["rename", { entityId: id, newName: "unsafe", writeFiles: "false" }],
      ["delete", {}],
      ["split", { entityId: id, newNames: [] }],
      ["bulk-delete", { entityIds: Array.from({ length: 101 }, () => id) }],
    ]) {
      assert.equal((await request(`entity-manager/author/${operation}`, token, body)).status, 400, operation);
    }
    assert.deepEqual(await json(`entity-manager/author/info/${id}`, token), before);
    assert.equal((await request("entity-manager/author/rename", restricted.accessToken, { entityId: id, newName: "Denied" })).status, 403);
    assert.equal((await request("entity-manager/author/browse?pageSize=101", token)).status, 400);
  } finally {
    await json("auth/logout", undefined, { refreshToken: session.refreshToken });
    await json("auth/logout", undefined, { refreshToken: restricted.refreshToken });
  }
});

test("IPAD-E03-A05-entities-preservation: entity edits preserve files, notes and reading state", async () => {
  const session = await login("ipad-editor");
  const token = session.accessToken;
  const bookID = Number(process.env.IPAD_ENTITY_BOOK_ID ?? "1");
  const before = await json(`books/${bookID}`, token);
  const marker = `Entity ${crypto.randomUUID()}`;
  const relations = {
    authors: before.authors.map((item) => item.name),
    genres: before.genres ?? [],
    tags: before.tags ?? [],
    publisher: before.publisher,
    seriesName: before.seriesName,
  };
  try {
    const delivered = await request(`books/files/${before.files[0].id}/serve`, token);
    const bytes = new Uint8Array(await delivered.arrayBuffer());
    const progress = await json(`books/files/${before.files[0].id}/progress`, token);
    const annotations = await json(`books/${bookID}/annotations?page=1&pageSize=100`, token);
    await json(
      `books/${bookID}/metadata`,
      token,
      {
        authors: [`${marker} author`],
        genres: [`${marker} genre`],
        tags: [`${marker} tag`],
        publisher: `${marker} publisher`,
        seriesName: `${marker} series`,
      },
      "PATCH",
    );
    for (const type of ["author", "genre", "tag", "publisher", "series"]) {
      const page = await json(`entity-manager/${type}/browse?search=${encodeURIComponent(marker)}&page=1&pageSize=25`, token);
      const source = page.items.find((item) => item.name === `${marker} ${type}`);
      assert.ok(source, type);
      const info = await json(`entity-manager/${type}/info/${encodeURIComponent(source.id)}`, token);
      assert.equal(info.bookCount, 1);
      assert.ok(info.bookTitles.includes(before.title));
      const safeInfo = await json(
        `entity-manager/${type}/info?${type === "publisher" ? "value" : "entityId"}=${encodeURIComponent(source.id)}`,
        token,
      );
      assert.deepEqual(safeInfo, info);
      const inline = type === "publisher";
      const rename = await json(`entity-manager/${type}/rename`, token, {
        ...(inline ? { currentValue: source.id } : { entityId: source.id }),
        newName: `${marker} corrected ${type}`,
        writeFiles: false,
      });
      assert.equal(rename.affectedBookCount, 1);
      const corrected = (await json(`entity-manager/${type}/browse?search=${encodeURIComponent(`${marker} corrected`)}&pageSize=25`, token)).items[0];
      assert.ok(corrected);
      const removed = await json(`entity-manager/${type}/delete`, token, {
        ...(inline ? { value: corrected.id } : { entityId: corrected.id }),
        mode: inline ? "inline" : "hard",
        writeFiles: false,
      });
      assert.equal(removed.affectedBookCount, 1);
    }
    const after = await json(`books/${bookID}`, token);
    assert.equal(after.id, before.id);
    assert.deepEqual(after.files, before.files);
    assert.deepEqual(await json(`books/files/${before.files[0].id}/progress`, token), progress);
    assert.equal(after.personalNote, before.personalNote);
    assert.deepEqual(await json(`books/${bookID}/annotations?page=1&pageSize=100`, token), annotations);
    const actual = await request(`books/files/${before.files[0].id}/serve`, token);
    assert.deepEqual(new Uint8Array(await actual.arrayBuffer()), bytes);
  } finally {
    await json(`books/${bookID}/metadata`, token, relations, "PATCH");
    await json("auth/logout", undefined, { refreshToken: session.refreshToken });
  }
});

test("IPAD-E03-A05-entities-merge-split: every baseline relationship merges without changing books or their content", async () => {
  const session = await login("ipad-editor");
  const token = session.accessToken;
  const sourceBookID = Number(process.env.IPAD_ENTITY_BOOK_ID ?? "1");
  const targetBookID = Number(process.env.IPAD_ENTITY_TARGET_BOOK_ID ?? "3");
  const sourceBook = await json(`books/${sourceBookID}`, token);
  const targetBook = await json(`books/${targetBookID}`, token);
  const marker = `Entity merge ${crypto.randomUUID()}`;
  const fields = {
    author: "authors",
    genre: "genres",
    tag: "tags",
    narrator: "narrators",
    publisher: "publisher",
    language: "language",
    series: "seriesName",
  };
  const restore = (book) => ({
    authors: book.authors.map((item) => item.name),
    audioMetadata: { narrators: (book.audioMetadata?.narrators ?? []).map((item) => item.name) },
    genres: book.genres,
    tags: book.tags,
    publisher: book.publisher,
    language: book.language,
    seriesName: book.seriesName,
  });
  try {
    for (const [type, field] of Object.entries(fields)) {
      const inline = type === "publisher" || type === "language";
      const isArray = ["authors", "genres", "tags", "narrators"].includes(field);
      const sourceName = `${marker} source ${type}`;
      const targetName = `${marker} target ${type}`;
      await json(
        `books/${sourceBookID}/metadata`,
        token,
        field === "narrators" ? { audioMetadata: { narrators: [sourceName] } } : { [field]: isArray ? [sourceName] : sourceName },
        "PATCH",
      );
      await json(
        `books/${targetBookID}/metadata`,
        token,
        field === "narrators" ? { audioMetadata: { narrators: [targetName] } } : { [field]: isArray ? [targetName] : targetName },
        "PATCH",
      );
      const items = (await json(`entity-manager/${type}/browse?search=${encodeURIComponent(marker)}&pageSize=40`, token)).items;
      const source = items.find((item) => item.name === sourceName);
      const target = items.find((item) => item.name === targetName);
      assert.ok(source && target, type);
      const merged = await json(`entity-manager/${type}/merge`, token, {
        ...(inline ? { targetValue: target.id, sourceValues: [source.id] } : { targetEntityId: target.id, sourceEntityIds: [source.id] }),
        writeFiles: false,
      });
      assert.equal(merged.affectedBookCount, 1, type);
      const mergedInfo = await json(`entity-manager/${type}/info?${inline ? "value" : "entityId"}=${encodeURIComponent(target.id)}`, token);
      assert.equal(mergedInfo.bookCount, 2, type);
      const book = await json(`books/${sourceBookID}`, token);
      assert.deepEqual(book.files, sourceBook.files);
      if (["author", "genre", "tag", "narrator"].includes(type)) {
        const split = await json(`entity-manager/${type}/split`, token, {
          entityId: target.id,
          newNames: [`${marker} split A ${type}`, `${marker} split B ${type}`],
          writeFiles: false,
        });
        assert.equal(split.affectedBookCount, 2, type);
        assert.equal(split.newEntities.length, 2, type);
        const removed = await json(`entity-manager/${type}/bulk-delete`, token, {
          entityIds: split.newEntities.map((item) => item.id),
          mode: "hard",
          writeFiles: false,
        });
        assert.equal(removed.results.length, 2, type);
        assert.deepEqual(removed.errors, []);
      }
    }
  } finally {
    await json(`books/${sourceBookID}/metadata`, token, restore(sourceBook), "PATCH");
    await json(`books/${targetBookID}/metadata`, token, restore(targetBook), "PATCH");
    await json("auth/logout", undefined, { refreshToken: session.refreshToken });
  }
});

test("IPAD-E03-A05-entities-duplicates: complete component pages, dismissed pages and restoration remain scoped and bounded", async () => {
  const session = await login("ipad-editor");
  const token = session.accessToken;
  const bookID = Number(process.env.IPAD_ENTITY_BOOK_ID ?? "1");
  const before = await json(`books/${bookID}`, token);
  const marker = `Entity duplicate ${crypto.randomUUID()}`;
  const names = Array.from({ length: 12 }, (_, index) => `${marker} ${String(index).padStart(2, "0")}`);
  try {
    await json(`books/${bookID}/metadata`, token, { tags: names }, "PATCH");
    await json("entity-manager/tag/duplicates/refresh", token, { minSimilarity: 0.7 });
    const deadline = Date.now() + 60_000;
    let scan;
    let component;
    while (Date.now() < deadline) {
      scan = await json("entity-manager/tag/duplicates/scan?minSimilarity=0.7&page=1&pageSize=20", token);
      component = scan.clusters.find((cluster) => cluster.entities.some((entity) => entity.name === names[0]));
      if (component) break;
      await new Promise((resolve) => setTimeout(resolve, 250));
    }
    assert.ok(component, "Fixture component must be returned");
    assert.equal(component.entityTotal, 12);
    assert.equal(component.pairTotal, 66);
    assert.equal(component.entities.length, 10);
    assert.equal(component.pairDetails.length, 10);
    assert.equal(component.detailsPageSize, 10);
    assert.equal(component.nextPage, 2);
    const seenEntities = new Set(component.entities.map((entity) => entity.name));
    const seenPairs = new Set(component.pairDetails.map((pair) => `${pair.idA}:${pair.idB}`));
    let nextPage = component.nextPage;
    while (nextPage !== null) {
      const page = await json(
        `entity-manager/tag/duplicates/cluster?clusterId=${encodeURIComponent(component.clusterId)}&page=${nextPage}&pageSize=10`,
        token,
      );
      assert.equal(page.page, nextPage);
      assert.equal(page.entityTotal, 12);
      assert.equal(page.pairTotal, 66);
      assert.ok(page.entities.length <= 10);
      assert.ok(page.pairDetails.length <= 10);
      for (const entity of page.entities) seenEntities.add(entity.name);
      for (const pair of page.pairDetails) {
        assert.ok(pair.nameA?.startsWith(marker));
        assert.ok(pair.nameB?.startsWith(marker));
        assert.ok(!seenPairs.has(`${pair.idA}:${pair.idB}`));
        seenPairs.add(`${pair.idA}:${pair.idB}`);
      }
      nextPage = page.nextPage;
    }
    assert.deepEqual([...seenEntities].sort(), names);
    assert.equal(seenPairs.size, 66);
    const pair = component.pairDetails[0];
    const body = { entityIdA: pair.idA, entityIdB: pair.idB };
    assert.equal((await request("entity-manager/tag/duplicates/dismiss", token, body)).status, 201);
    const dismissed = await json("entity-manager/tag/duplicates/dismissed-page?page=1&pageSize=20", token);
    assert.ok(dismissed.items.length <= 20);
    assert.ok(dismissed.items.some((item) => item.idA === pair.idA && item.idB === pair.idB));
    assert.equal((await request("entity-manager/tag/duplicates/undismiss", token, body)).status, 201);
    const restored = await json("entity-manager/tag/duplicates/dismissed-page?page=1&pageSize=20", token);
    assert.ok(!restored.items.some((item) => item.idA === pair.idA && item.idB === pair.idB));
    assert.equal((await request("entity-manager/tag/duplicates/cluster?clusterId=invalid&page=1&pageSize=10", token)).status, 400);
    assert.equal((await request("entity-manager/tag/duplicates/dismissed-page?page=1.5&pageSize=20", token)).status, 400);
  } finally {
    await json(`books/${bookID}/metadata`, token, { tags: before.tags }, "PATCH");
    await json("auth/logout", undefined, { refreshToken: session.refreshToken });
  }
});
