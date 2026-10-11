import assert from "node:assert/strict";
import { createHash, randomUUID } from "node:crypto";
import { test } from "node:test";

const base = process.env.IPAD_E04_API_URL ?? "http://127.0.0.1:16502/api/v1";
async function request(path, { token, headers = {}, body, method = body ? "POST" : "GET" } = {}) {
  return fetch(`${base}/${path}`, {
    method,
    headers: { ...(token ? { Authorization: `Bearer ${token}` } : {}), ...(body ? { "Content-Type": "application/json" } : {}), ...headers },
    ...(body ? { body: JSON.stringify(body) } : {}),
    signal: AbortSignal.timeout(20_000),
  });
}
async function json(path, options, expected = 200) {
  const response = await request(path, options);
  assert.equal(response.status, expected, await response.clone().text());
  return response.json();
}
const device = { deviceId: "content-policy-http", deviceModel: "Public HTTP regression", pluginVersion: "0.5.0" };

async function acquiredFile(bookId, format, headers) {
  const detail = await json(`koreader/plugin/catalog/books/${bookId}`, { headers });
  const file = detail.files.find((entry) => entry.format === format);
  assert.ok(file, `Book ${bookId} must advertise its ${format} acquisition`);
  assert.ok(["original", "audioless_epub"].includes(file.downloadVariant));
  const url = new URL(file.downloadUrl, base);
  assert.equal(url.origin, new URL(base).origin);
  const response = await fetch(url, { headers, signal: AbortSignal.timeout(20_000) });
  assert.equal(response.status, 200);
  const size = Number(response.headers.get("content-length"));
  assert.ok(Number.isSafeInteger(size) && size > 0 && size <= 16 * 1024 * 1024, "The two acquisition fixtures must remain bounded");
  const bytes = Buffer.from(await response.arrayBuffer());
  assert.equal(bytes.length, size);
  const digest = createHash("md5");
  // KOReader samples 1 KiB at offsets 0, 1 KiB, 4 KiB, 16 KiB, through 1 GiB.
  for (let index = -1; index <= 10; index++) {
    const offset = index < 0 ? 0 : 1024 * 4 ** index;
    if (offset >= bytes.length) break;
    digest.update(bytes.subarray(offset, offset + 1024));
  }
  return { file, hash: digest.digest("hex") };
}

test("IPAD-E04-A02/A03: known KOReader hashes enforce content policy for progress, exchange and linking", async (t) => {
  const owner = await json("auth/login", { body: { username: "ipad-owner", password: "IpadFixture123" } });
  const token = owner.accessToken;
  const book = await json("books/2", { token });
  const suffix = randomUUID().slice(0, 8);
  const username = `scope-${suffix}`;
  const password = "ScopePolicy123";
  const headers = { "x-auth-user": username, "x-auth-key": password };
  let account;
  let session;
  let tagged = false;
  let foreign;
  t.after(async () => {
    if (tagged) assert.equal((await request("books/2/metadata", { token, method: "PATCH", body: { tags: book.tags } })).status, 200);
    if (foreign) await request(`books/1/annotations/${foreign.id}`, { token, method: "DELETE" });
    if (account) assert.equal((await request(`users/${account.id}`, { token, method: "DELETE" })).status, 204);
    for (const value of [session, owner].filter(Boolean)) await request("auth/logout", { body: { refreshToken: value.refreshToken } });
  });
  account = await json(
    "users",
    {
      token,
      body: {
        username,
        name: "Content policy regression",
        email: `${username}@example.com`,
        libraryIds: [book.libraryId],
        permissionNames: ["koreader_sync", "annotation_manage_own", "library_download"],
      },
    },
    201,
  );
  assert.equal(
    (await request("auth/reset-password", { body: { token: new URL(account.resetUrl).searchParams.get("token"), newPassword: password } })).status,
    204,
  );
  session = await json("auth/login", { body: { username, password } });
  await json("koreader/credentials", { token: session.accessToken, body: { username, password } }, 201);
  const { file: excluded, hash: deniedHash } = await acquiredFile(2, "epub", headers);
  const { file: allowed, hash: allowedHash } = await acquiredFile(1, "pdf", headers);
  assert.notEqual(deniedHash, allowedHash);
  const known = await json(
    "koreader/plugin/match-check",
    {
      headers,
      body: {
        ...device,
        hashes: [deniedHash, allowedHash],
        books: [
          { hash: deniedHash, bookFileId: excluded.id, source: "current_file", metadataAmbiguous: false },
          { hash: allowedHash, bookFileId: allowed.id, source: "current_file", metadataAmbiguous: false },
        ],
      },
    },
    201,
  );
  for (const [hash, bookId, file] of [
    [deniedHash, 2, excluded],
    [allowedHash, 1, allowed],
  ]) {
    assert.deepEqual(
      known.matches.find((entry) => entry.hash === hash),
      { hash, bookId, bookFileId: file.id },
    );
  }
  foreign = await json(
    "books/1/annotations",
    { token, body: { bookFileId: allowed.id, cfi: "epubcfi(/6/2!/4/2/1:0)", text: `Other user's private note ${suffix}` } },
    201,
  );
  const pull = (kind, hash, changes = []) =>
    json(`koreader/plugin/${kind}/exchange`, { headers, body: { ...device, books: [{ hash, keys: [], keysComplete: false, changes }] } }, 201);
  const bookmark = { datetime: "2026-10-10 12:00:00", pos: "/body/DocFragment[1]/body/p/text().0", pageno: 1, note: "Private scoped dogear" };
  const annotation = {
    datetime: "2026-10-10 12:00:00",
    drawer: "lighten",
    posFormat: "xpointer",
    pos0: "/body/DocFragment[1]/body/p/text().0",
    pos1: "/body/DocFragment[1]/body/p/text().5",
    pageno: 1,
    text: "Private scoped highlight",
  };
  const beforeBookmark = await pull("bookmarks", deniedHash, [bookmark]);
  const beforeAnnotation = await pull("annotations", deniedHash, [annotation]);
  assert.equal(beforeBookmark.results[0].accepted, 1);
  assert.equal(beforeAnnotation.results[0].applied.created, 1);
  assert.equal(
    (
      await request("koreader/syncs/progress", {
        headers,
        method: "PUT",
        body: { document: deniedHash, percentage: 0.25, progress: "1", device: "HTTP", device_id: device.deviceId },
      })
    ).status,
    200,
  );
  const baselineProgress = await json(`koreader/syncs/progress/${deniedHash}`, { headers });
  const tagName = `Policy excluded ${suffix}`;
  assert.equal((await request("books/2/metadata", { token, method: "PATCH", body: { tags: [...book.tags, tagName] } })).status, 200);
  tagged = true;
  const tags = await json(`metadata/tags?q=${encodeURIComponent(tagName)}`, { token });
  const tag = tags.find((entry) => entry.name === tagName);
  assert.ok(tag);
  assert.equal((await request(`users/${account.id}/content-filters`, { token, method: "PUT", body: { excludeTagIds: [tag.id] } })).status, 204);
  await t.test("excluded known hash cannot read or mutate progress; same-library allowed hash works", async () => {
    assert.equal(
      (await request("koreader/syncs/progress", { headers, method: "PUT", body: { document: deniedHash, percentage: 0.9, progress: "9" } })).status,
      404,
    );
    assert.deepEqual(await json(`koreader/syncs/progress/${deniedHash}`, { headers }), {});
    assert.equal(
      (
        await request("koreader/syncs/progress", {
          headers,
          method: "PUT",
          body: { document: allowedHash, percentage: 0.1, progress: "1" },
        })
      ).status,
      200,
    );
    assert.equal((await json(`koreader/syncs/progress/${allowedHash}`, { headers })).percentage, 0.1);
  });
  await t.test("excluded annotation and bookmark imports/exports reveal no records and preserve stored state", async () => {
    for (const [kind, change] of [
      ["annotations", annotation],
      ["bookmarks", bookmark],
    ]) {
      const response = await pull(kind, deniedHash, [{ ...change, datetime: "2026-10-10 13:00:00" }]);
      assert.deepEqual(response.results, []);
      assert.deepEqual(response.unmatched, [deniedHash]);
      const ack = await json(
        `koreader/plugin/${kind}/exchange-ack`,
        { headers, body: { ...device, books: [{ hash: deniedHash, applied: [], deleted: [] }] } },
        201,
      );
      assert.deepEqual(ack.results, []);
      assert.deepEqual(ack.unmatched, [deniedHash]);
      const eligible = await pull(kind, allowedHash);
      assert.equal(eligible.results.length, 1);
      assert.ok(!JSON.stringify(eligible).includes(foreign.text));
      if (kind === "annotations") assert.ok(!eligible.results[0].toApply.add.some((entry) => entry.serverId === foreign.id));
    }
  });
  await t.test("plugin matching and automatic linking cannot reveal excluded books", async () => {
    const match = await json(
      "koreader/plugin/match-check",
      {
        headers,
        body: { ...device, hashes: [deniedHash, allowedHash], books: [{ hash: deniedHash, bookFileId: excluded.id, source: "current_file" }] },
      },
      201,
    );
    assert.deepEqual(
      match.matches.map((entry) => entry.hash),
      [allowedHash],
    );
    assert.equal((await request("koreader/plugin/catalog/books/2", { headers })).status, 404);
  });
  assert.equal((await request(`users/${account.id}/content-filters`, { token, method: "PUT", body: { excludeTagIds: [] } })).status, 204);
  assert.deepEqual(await json(`koreader/syncs/progress/${deniedHash}`, { headers }), baselineProgress);
  for (const [kind, count] of [
    ["annotations", beforeAnnotation.results[0].applied.created],
    ["bookmarks", beforeBookmark.results[0].accepted],
  ]) {
    const records = await json(`books/2/${kind}`, { token: session.accessToken });
    assert.equal(records.length, count);
  }
});
