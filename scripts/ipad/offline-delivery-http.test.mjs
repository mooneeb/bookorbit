import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { rename, writeFile } from "node:fs/promises";
import { test } from "node:test";

const base = process.env.IPAD_DELIVERY_API_URL ?? "http://localhost:16482/api/v1";

async function request(path, token, headers = {}) {
  return fetch(`${base}/${path}`, {
    headers: { ...(token ? { Authorization: `Bearer ${token}` } : {}), "Accept-Encoding": "identity", ...headers },
    signal: AbortSignal.timeout(30_000),
  });
}

async function login(username) {
  const response = await fetch(`${base}/auth/login`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ username, password: "IpadFixture123", clientKind: "native", deviceLabel: "Offline delivery HTTP QA" }),
  });
  assert.equal(response.status, 200);
  return response.json();
}

test("IPAD-E02-A04-delivery: owned source and audio bytes resume with one verified revision", async () => {
  const reader = await login("ipad-owner");
  const restricted = await login("ipad-restricted");
  try {
    const routes = [];
    for (const [bookID, format] of [
      [1, "pdf"],
      [2, "epub"],
      [10, "cbz"],
    ]) {
      const detail = await request(`books/${bookID}`, reader.accessToken);
      assert.equal(detail.status, 200);
      const file = (await detail.json()).files.find((entry) => entry.format === format);
      assert.ok(file, `fixture ${format} source`);
      routes.push(`books/files/${file.id}/serve`);
    }
    const manifest = await request("audiobooks/6/manifest", reader.accessToken);
    assert.equal(manifest.status, 200);
    routes.push(`audiobooks/6/assets/${(await manifest.json()).assets[0].assetId}/content`);
    for (const route of routes) {
      const full = await request(route, reader.accessToken);
      assert.equal(full.status, 200, route);
      assert.match(full.headers.get("content-disposition"), /^inline; filename="[^"]+"; filename\*=UTF-8''[^\r\n]+$/, route);
      const bytes = Buffer.from(await full.arrayBuffer());
      const etag = full.headers.get("etag");
      assert.match(etag, /^"[a-f0-9]{64}"$/, route);
      assert.equal(full.headers.get("content-length"), String(bytes.length), route);
      assert.equal(full.headers.get("x-content-sha256"), createHash("sha256").update(bytes).digest("hex"), route);
      const offset = Math.min(65_536, Math.floor(bytes.length / 2));
      const resumed = await request(route, reader.accessToken, { Range: `bytes=${offset}-`, "If-Range": etag });
      assert.equal(resumed.status, 206, route);
      assert.equal(resumed.headers.get("etag"), etag, route);
      assert.equal(resumed.headers.get("content-range"), `bytes ${offset}-${bytes.length - 1}/${bytes.length}`, route);
      assert.equal(resumed.headers.get("content-length"), String(bytes.length - offset), route);
      assert.deepEqual(Buffer.from(await resumed.arrayBuffer()), bytes.subarray(offset), route);
      for (const validator of ['"previous-source-revision"', `W/${etag}`]) {
        const restarted = await request(route, reader.accessToken, { Range: `bytes=${offset}-`, "If-Range": validator });
        assert.equal(restarted.status, 200, route);
        assert.equal(restarted.headers.get("content-range"), null, route);
        assert.deepEqual(Buffer.from(await restarted.arrayBuffer()), bytes, route);
      }
      const invalid = await request(route, reader.accessToken, { Range: `bytes=${bytes.length}-`, "If-Range": etag });
      assert.equal(invalid.status, 416, route);
      assert.equal(invalid.headers.get("content-range"), `bytes */${bytes.length}`, route);
      assert.equal((await request(route)).status, 401, route);
      assert.equal((await request(route, restricted.accessToken, { Range: "bytes=0-1", "If-Range": etag })).status, 403, route);
    }
  } finally {
    for (const session of [reader, restricted]) {
      const response = await fetch(`${base}/auth/logout`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ refreshToken: session.refreshToken }),
      });
      assert.equal(response.status, 200);
    }
  }
});

test("IPAD-E02-A04-readalong-delivery: stale narration validator restarts the complete selected resource", async () => {
  const session = await login("ipad-owner");
  try {
    const route = "epub/2/media-overlay/file/OPS/narration.m4a?fileId=2&sectionIndex=0";
    const full = await request(route, session.accessToken);
    assert.equal(full.status, 200);
    const bytes = Buffer.from(await full.arrayBuffer());
    const restarted = await request(route, session.accessToken, { Range: "bytes=1-", "If-Range": '"old-epub-revision"' });
    assert.equal(restarted.status, 200);
    assert.equal(restarted.headers.get("content-range"), null);
    assert.deepEqual(Buffer.from(await restarted.arrayBuffer()), bytes);
  } finally {
    await fetch(`${base}/auth/logout`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ refreshToken: session.refreshToken }),
    });
  }
});

test("IPAD-E02-A04-comic-delivery: selected page advertises its exact complete size", async () => {
  const session = await login("ipad-owner");
  try {
    const detail = await request("books/10", session.accessToken);
    const file = (await detail.json()).files.find((entry) => entry.format === "cbz");
    const response = await request(`cbz/files/${file.id}/pages/0`, session.accessToken);
    assert.equal(response.status, 200);
    const bytes = Buffer.from(await response.arrayBuffer());
    assert.equal(response.headers.get("content-length"), String(bytes.length));
  } finally {
    await fetch(`${base}/auth/logout`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ refreshToken: session.refreshToken }),
    });
  }
});

test("IPAD-E02-A04-replacement-delivery: interrupted bytes resume and equal-size source replacement starts a fresh checksum", async () => {
  const session = await login("ipad-owner");
  let sourcePath;
  let original;
  const replacementPath = (path) => `${path}.delivery-qa-${process.pid}`;
  try {
    const detail = await request("books/8", session.accessToken);
    assert.equal(detail.status, 200);
    const file = (await detail.json()).files.find((entry) => entry.format === "pdf");
    assert.match(file.absolutePath, /bookorbit-ipad-[^/]+\/cover-book-8\.pdf$/);
    sourcePath = file.absolutePath;
    const route = `books/files/${file.id}/serve`;
    original = Buffer.from(await (await request(route, session.accessToken)).arrayBuffer());
    const firstRevision = Buffer.concat([original, Buffer.from("\n% offline-delivery-QA\n"), Buffer.alloc(512 * 1024, 0x20)]);
    await writeFile(replacementPath(sourcePath), firstRevision);
    await rename(replacementPath(sourcePath), sourcePath);
    const full = await request(route, session.accessToken);
    const etag = full.headers.get("etag");
    const reader = full.body.getReader();
    const { value: prefix, done } = await reader.read();
    assert.equal(done, false);
    assert.ok(prefix.length > 0 && prefix.length < firstRevision.length);
    await reader.cancel();
    const resumed = await request(route, session.accessToken, { Range: `bytes=${prefix.length}-`, "If-Range": etag });
    assert.equal(resumed.status, 206);
    const completed = Buffer.concat([Buffer.from(prefix), Buffer.from(await resumed.arrayBuffer())]);
    assert.deepEqual(completed, firstRevision);
    assert.equal(createHash("sha256").update(completed).digest("hex"), resumed.headers.get("x-content-sha256"));
    const secondRevision = Buffer.from(firstRevision);
    secondRevision[secondRevision.length - 1] = 0x0a;
    await writeFile(replacementPath(sourcePath), secondRevision);
    await rename(replacementPath(sourcePath), sourcePath);
    const replaced = await request(route, session.accessToken, { Range: `bytes=${prefix.length}-`, "If-Range": etag });
    assert.equal(replaced.status, 200);
    assert.notEqual(replaced.headers.get("etag"), etag);
    assert.equal(replaced.headers.get("content-length"), String(secondRevision.length));
    const delivered = Buffer.from(await replaced.arrayBuffer());
    assert.deepEqual(delivered, secondRevision);
    assert.equal(createHash("sha256").update(delivered).digest("hex"), replaced.headers.get("x-content-sha256"));
  } finally {
    if (sourcePath && original) {
      await writeFile(replacementPath(sourcePath), original);
      await rename(replacementPath(sourcePath), sourcePath);
    }
    await fetch(`${base}/auth/logout`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ refreshToken: session.refreshToken }),
    });
  }
});
