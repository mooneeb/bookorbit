import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { after, before, test } from "node:test";
import { mkdir, readFile, rename, writeFile } from "node:fs/promises";
import { join } from "node:path";

const base = process.env.IPAD_E04_BASE_URL;
if (!base || !["localhost", "127.0.0.1"].includes(new URL(base).hostname))
  throw new Error("Kobo acknowledgement tests require the isolated real harness");
async function request(path, { token, body, cursor } = {}) {
  const response = await fetch(`${base}/api/v1/${path}`, {
    method: body ? "POST" : "GET",
    headers: {
      ...(token ? { authorization: `Bearer ${token}` } : {}),
      ...(body ? { "content-type": "application/json" } : {}),
      ...(cursor ? { "x-kobo-synctoken": cursor } : {}),
    },
    ...(body ? { body: JSON.stringify(body) } : {}),
    signal: AbortSignal.timeout(20000),
  });
  assert.equal(response.ok, true, await response.clone().text());
  return response;
}
async function json(path, options) {
  return (await request(path, options)).json();
}
let adminToken;
let readerToken;
let reader;
before(async () => {
  adminToken = (await json("auth/login", { body: { username: "ipad-owner", password: "IpadFixture123" } })).accessToken;
  const detail = await json("books/1", { token: adminToken });
  const username = `kobo-ack-isolated-${randomUUID().slice(0, 8)}`;
  reader = await json("users", {
    token: adminToken,
    body: {
      username,
      name: username,
      email: `${username}@example.test`,
      permissionNames: ["kobo_sync", "library_download", "library_edit_metadata", "annotation_manage_own"],
      libraryIds: [detail.libraryId],
    },
  });
  assert.equal(
    (await request("auth/reset-password", { body: { token: new URL(reader.resetUrl).searchParams.get("token"), newPassword: "IpadFixture123" } }))
      .status,
    204,
  );
  readerToken = (await json("auth/login", { body: { username, password: "IpadFixture123" } })).accessToken;
});
after(async () => {
  if (reader) {
    const response = await fetch(`${base}/api/v1/users/${reader.id}`, { method: "DELETE", headers: { authorization: `Bearer ${adminToken}` } });
    assert.equal(response.status, 204);
  }
});
const ids = (entries) =>
  entries.flatMap((entry) => {
    const entitlement = entry.NewEntitlement?.BookEntitlement ?? entry.ChangedProductMetadata?.BookEntitlement;
    return entitlement ? [entitlement.Id] : [];
  });
async function page(device, cursor) {
  const response = await request(`kobo/${device.token}/v1/library/sync`, { cursor });
  return {
    entries: await response.json(),
    cursor: response.headers.get("x-kobo-synctoken"),
    more: response.headers.get("x-kobo-sync") === "continue",
  };
}

test("IPAD-E04-A03 Kobo interrupted page retry, exact token acknowledgment, reordered cursor and device isolation", async () => {
  const owner = readerToken;
  const collection = await json("collections", { token: owner, body: { name: `Ack ${randomUUID()}`, icon: "Folder", syncToKobo: true } });
  const device = await json("kobo/devices", { token: owner, body: { name: `Ack ${randomUUID()}` } });
  const other = await json("kobo/devices", { token: owner, body: { name: `Ack isolation ${randomUUID()}` } });
  try {
    await json(`collections/${collection.id}/books`, { token: owner, body: { bookIds: [1, 2] } });
    const first = await page(device);
    assert.ok(ids(first.entries).length > 0);
    assert.equal(first.more, true, "even final book page requires client acknowledgment");
    const snapshotId = JSON.parse(Buffer.from(first.cursor.slice(3), "base64").toString()).snapshotId;
    const legacyCursor = `PX.${Buffer.from(JSON.stringify({ snapshotId })).toString("base64")}`;
    const retry = await page(device, legacyCursor);
    assert.deepEqual(ids(retry.entries), ids(first.entries), "last acknowledged legacy token must replay every unacknowledged book");
    const upstreamRetry = await page(device, "legacy-opaque-upstream-cursor");
    assert.deepEqual(ids(upstreamRetry.entries), ids(first.entries));
    assert.equal(retry.cursor, first.cursor);
    const interrupted = await fetch(`${base}/api/v1/kobo/${device.token}/v1/library/sync`);
    const reader = interrupted.body.getReader();
    await reader.read();
    await reader.cancel();
    const afterAbort = await page(device);
    assert.deepEqual(ids(afterAbort.entries), ids(first.entries));
    const isolated = await page(other, first.cursor);
    assert.deepEqual(ids(isolated.entries), ids(first.entries), "foreign device cursor cannot acknowledge its own pending catalog");
    const advanced = await page(device, first.cursor);
    assert.equal(ids(advanced.entries).length, 0);
    assert.ok(
      advanced.entries.some((entry) => entry.ChangedTag),
      "acknowledged catalog finishes with collection replacements",
    );
    const duplicate = await page(device, first.cursor);
    assert.equal(ids(duplicate.entries).length, 0, "duplicate token must not resurrect completed pages");
    const isolatedRetry = await page(other, first.cursor);
    assert.deepEqual(ids(isolatedRetry.entries), ids(isolated.entries));
  } finally {
    for (const path of [`kobo/devices/${device.id}`, `kobo/devices/${other.id}`, `collections/${collection.id}`]) {
      const response = await fetch(`${base}/api/v1/${path}`, { method: "DELETE", headers: { authorization: `Bearer ${owner}` } });
      assert.equal(response.status, 204);
    }
  }
});

test("IPAD-E04-A04 Kobo pending page survives server restart and resumes current PDF revision with complete tags", async () => {
  const restartDirectory = process.env.IPAD_E04_RESTART_DIRECTORY;
  assert.ok(restartDirectory, "controlled retained harness restart seam is required");
  const owner = readerToken;
  const device = await json("kobo/devices", { token: owner, body: { name: `Restart ${randomUUID()}` } });
  const collection = await json("collections", { token: owner, body: { name: `Restart ${randomUUID()}`, icon: "Folder", syncToKobo: true } });
  let annotation;
  try {
    await json(`collections/${collection.id}/books`, { token: owner, body: { bookIds: [1] } });
    const first = await page(device);
    const descriptor = await json("annotations/native/files/1/source?bookId=1&page=0", { token: owner });
    const clientId = randomUUID();
    const mutation = await json("annotations/native/source-ink/1/1/operations", {
      token: owner,
      body: {
        deviceId: "Kobo-ack-restart",
        operations: [
          {
            operationId: randomUUID(),
            clientId,
            bookId: 1,
            baseVersion: 0,
            action: "create",
            payload: {
              kind: "pdf_ink",
              bookFileId: 1,
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
            },
          },
        ],
      },
    });
    assert.equal(mutation.results[0].status, "applied");
    annotation = mutation.results[0].annotation;
    const current = await json("annotations/native/files/1/source?bookId=1&page=0", { token: owner });
    assert.notEqual(current.sourceRevision, descriptor.sourceRevision);
    const requestId = randomUUID();
    await mkdir(restartDirectory, { recursive: true });
    await writeFile(join(restartDirectory, "request.tmp.json"), JSON.stringify({ requestId }));
    await rename(join(restartDirectory, "request.tmp.json"), join(restartDirectory, "request.json"));
    const deadline = Date.now() + 60000;
    while (true) {
      try {
        if (JSON.parse(await readFile(join(restartDirectory, "ready.json"), "utf8")).requestId === requestId) break;
      } catch {}
      assert.ok(Date.now() < deadline, "retained server restart must finish");
      await new Promise((resolve) => setTimeout(resolve, 120));
    }
    const resumed = await page(device);
    assert.deepEqual(ids(resumed.entries), ids(first.entries), "restart must retain every unacknowledged book");
    const pdf = resumed.entries.find((entry) =>
      entry.NewEntitlement?.BookMetadata?.DownloadUrls?.some((url) => url.Format === "PDF"),
    )?.NewEntitlement;
    assert.ok(pdf);
    const download = await request(`kobo/${device.token}/v1/books/${pdf.BookEntitlement.Id}/download`);
    assert.equal(download.headers.get("x-bookorbit-source-revision"), current.sourceRevision);
    await download.arrayBuffer();
    let cursor = resumed.cursor;
    let completed;
    for (let round = 0; round < 10; round++) {
      completed = await page(device, cursor);
      cursor = completed.cursor;
      if (!completed.more) break;
    }
    assert.equal(completed.more, false);
    const tag = completed.entries.find((entry) => entry.ChangedTag?.Tag?.Id === `col-${collection.id}`)?.ChangedTag.Tag;
    assert.ok(tag);
    assert.deepEqual(
      tag.Items.map((item) => item.RevisionId),
      [pdf.BookEntitlement.Id],
    );
    const abort = await fetch(`${base}/api/v1/kobo/${device.token}/v1/library/sync`, { headers: { "x-kobo-synctoken": cursor } });
    await abort.body.cancel();
    const replacement = await page(device, cursor);
    const retryTag = replacement.entries.find((entry) => entry.ChangedTag?.Tag?.Id === `col-${collection.id}`)?.ChangedTag.Tag;
    assert.deepEqual(retryTag.Items, tag.Items, "aborted final tag stream must rebuild full replacement");
  } finally {
    if (annotation) {
      const source = await json("annotations/native/files/1/source?bookId=1&page=0", { token: owner });
      await json("annotations/native/source-ink/1/1/operations", {
        token: owner,
        body: {
          deviceId: "Kobo-ack-restart",
          operations: [
            {
              operationId: randomUUID(),
              clientId: annotation.clientId,
              bookId: 1,
              annotationId: annotation.id,
              baseVersion: annotation.version,
              action: "delete",
              payload: { sourceRevision: source.sourceRevision, pageFingerprint: source.pageFingerprint },
            },
          ],
        },
      });
    }
    for (const path of [`kobo/devices/${device.id}`, `collections/${collection.id}`]) {
      const response = await fetch(`${base}/api/v1/${path}`, { method: "DELETE", headers: { authorization: `Bearer ${owner}` } });
      assert.equal(response.status, 204);
    }
  }
});
