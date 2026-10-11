import assert from "node:assert/strict";
import { createServer } from "node:http";
import test from "node:test";
import { setTimeout as delay } from "node:timers/promises";
import { startE03ResponseProxy } from "./e03-response-proxy.mjs";

test("E03 fault proxy forwards the actual mutation once and holds its committed response", async () => {
  let writes = 0;
  let receivedBody;
  const upstream = createServer(async (incoming, outgoing) => {
    const chunks = [];
    for await (const chunk of incoming) chunks.push(chunk);
    receivedBody = Buffer.concat(chunks).toString();
    writes++;
    outgoing.writeHead(200, { "content-type": "application/json" }).end(JSON.stringify({ writes, actual: true }));
  });
  await new Promise((resolve) => upstream.listen(0, "127.0.0.1", resolve));
  const proxy = await startE03ResponseProxy({ port: 0, upstreamPort: upstream.address().port });
  try {
    assert.equal((await fetch(`${proxy.origin}/__faults/bulk/arm`, { method: "POST" })).status, 204);
    let delivered = false;
    const response = fetch(`${proxy.origin}/api/v1/books/bulk-edit-metadata`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ bookIds: [1, 2], publisher: "E03 proxy fixture" }),
    }).then((result) => {
      delivered = true;
      return result;
    });
    for (let attempt = 0; attempt < 100; attempt++) {
      if ((await (await fetch(`${proxy.origin}/__faults/bulk/held`)).json()).held) break;
      await delay(10);
    }
    assert.equal((await (await fetch(`${proxy.origin}/__faults/bulk/held`)).json()).held, true);
    assert.equal(writes, 1);
    assert.deepEqual(JSON.parse(receivedBody), { bookIds: [1, 2], publisher: "E03 proxy fixture" });
    assert.equal(delivered, false);
    assert.equal((await fetch(`${proxy.origin}/__faults/bulk/release`, { method: "POST" })).status, 204);
    assert.deepEqual(await (await response).json(), { writes: 1, actual: true });
    assert.equal(writes, 1);
  } finally {
    await proxy.close();
    await new Promise((resolve) => upstream.close(resolve));
  }
});

test("E03 acquisition fault holds a later chunk before forwarding, cancellation preserves the committed offset", async () => {
  const committedOffsets = [];
  const upstream = createServer(async (incoming, outgoing) => {
    for await (const _chunk of incoming) {
      /* consume the actual request stream */
    }
    committedOffsets.push(Number(incoming.headers["upload-offset"]));
    outgoing.writeHead(201, { "content-type": "application/json" }).end(JSON.stringify({ receivedBytes: committedOffsets.at(-1) + 4 }));
  });
  await new Promise((resolve) => upstream.listen(0, "127.0.0.1", resolve));
  const proxy = await startE03ResponseProxy({ port: 0, upstreamPort: upstream.address().port });
  try {
    assert.equal((await fetch(`${proxy.origin}/__faults/acquisition/arm`, { method: "POST" })).status, 204);
    const path = `${proxy.origin}/api/v1/uploads/11111111-1111-4111-8111-111111111111/chunks`;
    assert.equal((await fetch(path, { method: "POST", headers: { "Upload-Offset": "0" }, body: "abcd" })).status, 201);
    const controller = new AbortController();
    const interrupted = fetch(path, { method: "POST", headers: { "Upload-Offset": "4" }, body: "efgh", signal: controller.signal }).catch(
      (error) => error,
    );
    let snapshot;
    for (let attempt = 0; attempt < 100; attempt++) {
      snapshot = await (await fetch(`${proxy.origin}/__faults/acquisition/held`)).json();
      if (snapshot.held) break;
      await delay(10);
    }
    assert.deepEqual(snapshot, { armed: false, held: true, sessionId: "11111111-1111-4111-8111-111111111111", offset: 4 });
    assert.deepEqual(committedOffsets, [0]);
    controller.abort();
    assert.equal((await interrupted).name, "AbortError");
    assert.equal((await fetch(`${proxy.origin}/__faults/acquisition/reset`, { method: "POST" })).status, 204);
    assert.equal((await fetch(path, { method: "POST", headers: { "Upload-Offset": "4" }, body: "efgh" })).status, 201);
    assert.deepEqual(committedOffsets, [0, 4]);
  } finally {
    await proxy.close();
    await new Promise((resolve) => upstream.close(resolve));
  }
});

test("E03 acquisition seed control stages a real temporary file through the supplied fixture boundary", async () => {
  const { mkdtemp, copyFile, readFile, writeFile, rm } = await import("node:fs/promises");
  const { tmpdir } = await import("node:os");
  const { join } = await import("node:path");
  const folder = await mkdtemp(join(tmpdir(), "bookorbit-e03-dock-"));
  const source = join(folder, "source.pdf");
  const target = join(folder, "staged.pdf");
  await writeFile(source, "%PDF-1.7\nfixture protocol bytes");
  const proxy = await startE03ResponseProxy({
    port: 0,
    seedDock: async () => {
      await copyFile(source, target);
      return { filename: "staged.pdf" };
    },
  });
  try {
    const response = await fetch(`${proxy.origin}/__faults/acquisition/seed-dock`, { method: "POST" });
    assert.equal(response.status, 200);
    assert.deepEqual(await response.json(), { filename: "staged.pdf" });
    assert.deepEqual(await readFile(target), await readFile(source));
  } finally {
    await proxy.close();
    await rm(folder, { recursive: true, force: true });
  }
});
