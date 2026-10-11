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

test("IPAD-E03-A05-entity-dismissed-pagination: every entity type exposes a bounded, stable dismissed page", async () => {
  const session = await json("auth/login", undefined, {
    username: "ipad-editor",
    password: process.env.IPAD_FIXTURE_PASSWORD ?? "IpadFixture123",
    clientKind: "native",
    deviceLabel: "Entity scaling HTTP",
  });
  try {
    for (const type of ["author", "genre", "tag", "narrator", "series", "publisher", "language"]) {
      const path = `entity-manager/${type}/duplicates/dismissed-page?page=1&pageSize=20`;
      const response = await request(path, session.accessToken);
      assert.equal(response.status, 200, type);
      const body = await response.text();
      assert.ok(Buffer.byteLength(body) < 1024 * 1024, type);
      const page = JSON.parse(body);
      assert.ok(page.items.length <= 20, type);
      assert.equal(page.page, 1);
      assert.equal(page.pageSize, 20);
      assert.ok(page.total >= page.items.length);
      assert.deepEqual(await json(path, session.accessToken), page);
      assert.equal((await request(`entity-manager/${type}/duplicates/dismissed-page?pageSize=101`, session.accessToken)).status, 400);
    }
  } finally {
    await json("auth/logout", undefined, { refreshToken: session.refreshToken });
  }
});

test("IPAD-E03-A05-entity-cluster-continuation: a 50000-member component stays bounded and exposes every page", { timeout: 120000 }, async () => {
  const { createRequire } = await import("node:module");
  const require = createRequire(new URL("../../server/package.json", import.meta.url));
  const { Client } = require("pg");
  const db = new Client({ connectionString: process.env.E2E_DATABASE_URL ?? process.env.DATABASE_URL });
  await db.connect();
  const session = await json("auth/login", undefined, {
    username: "ipad-editor",
    password: process.env.IPAD_FIXTURE_PASSWORD ?? "IpadFixture123",
    clientKind: "native",
    deviceLabel: "Entity continuation HTTP",
  });
  const marker = `EntityScaling-${crypto.randomUUID()}-`;
  const bookID = Number(process.env.IPAD_ENTITY_BOOK_ID ?? "1");
  let previousStatus;
  try {
    previousStatus = (await db.query("SELECT * FROM entity_duplicate_scan_status WHERE entity_type='genre'")).rows[0];
    await db.query("BEGIN");
    await db.query("INSERT INTO genres(name) SELECT $1 || lpad(n::text, 5, $2) FROM generate_series(1, 50000) n", [marker, "0"]);
    await db.query("INSERT INTO book_genres(book_id,genre_id) SELECT $1,id FROM genres WHERE name LIKE $2", [bookID, `${marker}%`]);
    await db.query(
      `INSERT INTO entity_duplicate_candidates(entity_type,entity_id_a,entity_id_b,sim_score)
      SELECT 'genre',id,next_id,0.99 FROM (SELECT id,lead(id) OVER(ORDER BY id) next_id FROM genres WHERE name LIKE $1) entries WHERE next_id IS NOT NULL`,
      [`${marker}%`],
    );
    await db.query(`INSERT INTO entity_duplicate_scan_status(entity_type,is_computing,computed_at,threshold)
      VALUES ('genre',false,now(),0.1) ON CONFLICT(entity_type) DO UPDATE SET is_computing=false,computed_at=now(),threshold=0.1,error_message=NULL`);
    await db.query("COMMIT");
    const scanResponse = await request("entity-manager/genre/duplicates/scan?page=1&pageSize=20&minSimilarity=0.98", session.accessToken);
    assert.equal(scanResponse.status, 200, await scanResponse.clone().text());
    const scanText = await scanResponse.text();
    assert.ok(Buffer.byteLength(scanText) < 1024 * 1024);
    const cluster = JSON.parse(scanText).clusters.find((item) => item.entities.some((entity) => entity.name.startsWith(marker)));
    assert.ok(cluster);
    assert.equal(cluster.entityTotal, 50000);
    assert.equal(cluster.pairTotal, 49999);
    assert.equal(cluster.entities.length, 10);
    assert.equal(cluster.pairDetails.length, 10);
    assert.equal(cluster.nextPage, 2);
    const observed = new Set(cluster.entities.map((entity) => entity.id));
    const candidatePairs = [...cluster.pairDetails];
    for (const page of [2, 5000]) {
      const path = `entity-manager/genre/duplicates/cluster?clusterId=${encodeURIComponent(cluster.clusterId)}&page=${page}&pageSize=10`;
      const response = await request(path, session.accessToken);
      assert.equal(response.status, 200, await response.clone().text());
      const text = await response.text();
      assert.ok(Buffer.byteLength(text) < 1024 * 1024);
      const details = JSON.parse(text);
      assert.equal(details.entityTotal, 50000);
      assert.equal(details.pairTotal, 49999);
      assert.equal(details.entities.length, 10);
      assert.ok(details.pairDetails.length <= 10);
      for (const entity of details.entities) {
        assert.ok(!observed.has(entity.id));
        observed.add(entity.id);
      }
      candidatePairs.push(...details.pairDetails);
      for (const pair of details.pairDetails) {
        assert.ok(pair.nameA.startsWith(marker));
        assert.ok(pair.nameB.startsWith(marker));
      }
      assert.equal(details.nextPage, page === 5000 ? null : page + 1);
      assert.deepEqual(await json(path, session.accessToken), details);
    }
    const beforeDismissals = await json("entity-manager/genre/duplicates/dismissed-page?page=1&pageSize=20", session.accessToken);
    for (const pair of candidatePairs.slice(0, 21)) {
      assert.ok(
        (
          await request("entity-manager/genre/duplicates/dismiss", session.accessToken, {
            entityIdA: pair.idA,
            entityIdB: pair.idB,
            reason: "Verified distinct editions",
          })
        ).ok,
      );
    }
    const dismissedFirst = await json("entity-manager/genre/duplicates/dismissed-page?page=1&pageSize=20", session.accessToken);
    const dismissedSecond = await json("entity-manager/genre/duplicates/dismissed-page?page=2&pageSize=20", session.accessToken);
    assert.equal(dismissedFirst.total, beforeDismissals.total + 21);
    assert.equal(dismissedFirst.items.length, 20);
    assert.ok(dismissedFirst.items.every((pair) => pair.nameA.startsWith(marker) && pair.nameB.startsWith(marker)));
    assert.ok(dismissedSecond.items[0].nameA.startsWith(marker));
    const firstIDs = new Set(dismissedFirst.items.map((pair) => pair.id));
    assert.ok(dismissedSecond.items.every((pair) => !firstIDs.has(pair.id)));
    assert.deepEqual(await json("entity-manager/genre/duplicates/dismissed-page?page=2&pageSize=20", session.accessToken), dismissedSecond);
    for (const pair of candidatePairs.slice(0, 21)) {
      assert.ok((await request("entity-manager/genre/duplicates/undismiss", session.accessToken, { entityIdA: pair.idA, entityIdB: pair.idB })).ok);
    }
    assert.equal(
      (await json("entity-manager/genre/duplicates/dismissed-page?page=1&pageSize=20", session.accessToken)).total,
      beforeDismissals.total,
    );
    assert.equal((await request("entity-manager/genre/duplicates/cluster?clusterId=invalid&page=1&pageSize=10", session.accessToken)).status, 400);
  } finally {
    await db.query("ROLLBACK");
    await db.query(
      "DELETE FROM dismissed_duplicate_pairs WHERE entity_type=$1 AND (entity_id_a IN (SELECT id FROM genres WHERE name LIKE $2) OR entity_id_b IN (SELECT id FROM genres WHERE name LIKE $2))",
      ["genre", `${marker}%`],
    );
    await db.query(
      "DELETE FROM entity_duplicate_candidates WHERE entity_type=$1 AND (entity_id_a IN (SELECT id FROM genres WHERE name LIKE $2) OR entity_id_b IN (SELECT id FROM genres WHERE name LIKE $2))",
      ["genre", `${marker}%`],
    );
    await db.query("DELETE FROM book_genres WHERE genre_id IN (SELECT id FROM genres WHERE name LIKE $1)", [`${marker}%`]);
    await db.query("DELETE FROM genres WHERE name LIKE $1", [`${marker}%`]);
    if (previousStatus) {
      await db.query(
        `UPDATE entity_duplicate_scan_status SET is_computing=$1,computed_at=$2,threshold=$3,total_pairs=$4,total_count=$5,processed_count=$6,error_message=$7 WHERE entity_type='genre'`,
        [
          previousStatus.is_computing,
          previousStatus.computed_at,
          previousStatus.threshold,
          previousStatus.total_pairs,
          previousStatus.total_count,
          previousStatus.processed_count,
          previousStatus.error_message,
        ],
      );
    } else {
      await db.query("DELETE FROM entity_duplicate_scan_status WHERE entity_type='genre'");
    }
    await db.end();
    await json("auth/logout", undefined, { refreshToken: session.refreshToken });
  }
});

test("IPAD-E03-A05-inline-dismissals: publisher dismissal excludes a candidate and restoration brings it back", async () => {
  const session = await json("auth/login", undefined, {
    username: "ipad-editor",
    password: process.env.IPAD_FIXTURE_PASSWORD ?? "IpadFixture123",
    clientKind: "native",
    deviceLabel: "Inline duplicate HTTP",
  });
  const sourceID = Number(process.env.IPAD_ENTITY_BOOK_ID ?? "1");
  const targetID = Number(process.env.IPAD_ENTITY_TARGET_BOOK_ID ?? "3");
  const source = await json(`books/${sourceID}`, session.accessToken);
  const target = await json(`books/${targetID}`, session.accessToken);
  const marker = `Publisher proof ${crypto.randomUUID()}`;
  const names = [`${marker} edition A`, `${marker} edition B`];
  const pair = { valueA: names[0], valueB: names[1] };
  const scan = () => json("entity-manager/publisher/duplicates/scan?page=1&pageSize=20&minSimilarity=0.7", session.accessToken);
  const hasPair = (result) =>
    result.clusters.some((cluster) =>
      cluster.pairDetails.some(
        (candidate) => new Set([candidate.idA, candidate.idB]).has(names[0]) && new Set([candidate.idA, candidate.idB]).has(names[1]),
      ),
    );
  try {
    await json(`books/${sourceID}/metadata`, session.accessToken, { publisher: names[0] }, "PATCH");
    await json(`books/${targetID}/metadata`, session.accessToken, { publisher: names[1] }, "PATCH");
    assert.ok(hasPair(await scan()));
    assert.ok((await request("entity-manager/publisher/duplicates/dismiss", session.accessToken, pair)).ok);
    assert.equal(hasPair(await scan()), false);
    const dismissed = await json("entity-manager/publisher/duplicates/dismissed-page?page=1&pageSize=20", session.accessToken);
    assert.ok(
      dismissed.items.some(
        (candidate) => new Set([candidate.idA, candidate.idB]).has(names[0]) && new Set([candidate.idA, candidate.idB]).has(names[1]),
      ),
    );
    assert.ok((await request("entity-manager/publisher/duplicates/undismiss", session.accessToken, pair)).ok);
    assert.ok(hasPair(await scan()));
  } finally {
    await request("entity-manager/publisher/duplicates/undismiss", session.accessToken, pair);
    await json(`books/${sourceID}/metadata`, session.accessToken, { publisher: source.publisher ?? null }, "PATCH");
    await json(`books/${targetID}/metadata`, session.accessToken, { publisher: target.publisher ?? null }, "PATCH");
    await json("auth/logout", undefined, { refreshToken: session.refreshToken });
  }
});
