import assert from "node:assert/strict";
import { createServer } from "node:http";
import test from "node:test";
import { startFaultProxy } from "./fault-proxy.mjs";

async function transport(t, timeoutMs = 30_000) {
  const requests = [];
  const upstream = createServer(async (incoming, outgoing) => {
    const chunks = [];
    for await (const chunk of incoming) chunks.push(chunk);
    requests.push({ method: incoming.method, url: incoming.url, headers: incoming.headers, body: Buffer.concat(chunks).toString("utf8") });
    outgoing.writeHead(incoming.method === "GET" ? 200 : 418, { "Content-Type": "text/plain", "X-E04-Upstream": "unchanged" }).end("transport echo");
  });
  await new Promise((resolve) => upstream.listen(0, "127.0.0.1", resolve));
  const stop = await startFaultProxy({ port: 0, upstreamPort: upstream.address().port, personalWriteHoldTimeoutMs: timeoutMs });
  let closed = false;
  async function close() {
    if (closed) return;
    closed = true;
    await stop();
  }
  t.after(async () => {
    await close();
    upstream.closeAllConnections();
    await new Promise((resolve) => upstream.close(resolve));
  });
  const base = `http://127.0.0.1:${stop.port}`;
  async function control(action, body) {
    return fetch(`${base}/__faults/personal-record/${action}`, {
      method: "POST",
      ...(body ? { headers: { "Content-Type": "application/json" }, body: JSON.stringify(body) } : {}),
    });
  }
  return { requests, base, stop: close, control };
}

test("personal hold queues three writes after preflight and forwards unchanged HTTP bytes and upstream status", async (t) => {
  const { requests, base, control } = await transport(t);
  const paths = ["status", "personal-note", "rating"].map((field) => `/api/v1/books/1/${field}`);
  for (const path of paths) assert.equal((await control("write-arm", { method: "PATCH", path })).status, 204);
  assert.equal((await control("write-arm", { method: "PATCH", path: paths[0] })).status, 409);
  assert.equal((await control("write-arm", { method: "PATCH", path: "/api/v1/books/2/rating" })).status, 409);
  assert.equal((await control("write-arm", { method: "DELETE", path: paths[0] })).status, 400);
  assert.equal((await fetch(`${base}/api/v1/books/1`)).status, 200);
  for (const [index, path] of paths.entries()) {
    const body = JSON.stringify({ fixture: `unchanged-${index}`, unicode: "読書" });
    const pending = fetch(`${base}${path}?fixture=kept`, {
      method: "PATCH",
      headers: { Authorization: "Bearer fixture-transport-only", "Content-Type": "application/json" },
      body,
    });
    assert.equal((await fetch(`${base}/__faults/personal-record/held`)).status, 200);
    const state = await (await fetch(`${base}/__faults/personal-record/state`)).json();
    assert.equal(state.held, true);
    assert.equal(state.path, path);
    assert.deepEqual(state.queuedPaths, paths.slice(index + 1));
    assert.equal(requests.length, index + 1, "held write has not reached upstream");
    assert.equal((await control("release")).status, 204);
    const response = await pending;
    assert.equal(response.status, 418);
    assert.equal(response.headers.get("x-e04-upstream"), "unchanged");
    assert.equal(await response.text(), "transport echo");
    const received = requests.at(-1);
    assert.equal(received.url, `${path}?fixture=kept`);
    assert.equal(received.headers.authorization, "Bearer fixture-transport-only");
    assert.equal(received.body, body);
  }
  const state = await (await fetch(`${base}/__faults/personal-record/state`)).json();
  assert.equal(state.held, false);
  assert.equal(state.path, null);
  assert.equal(state.released, 3);
  assert.equal(state.upstreamStatus, 418);
  const traffic = await (await fetch(`${base}/__faults/annotations/traffic`)).json();
  assert.deepEqual(
    traffic.items.filter((item) => item.method === "PATCH").map((item) => item.status),
    [418, 418, 418],
  );
});

test("reset and timeout cancel held writes without forwarding them", async (t) => {
  const { requests, base, control } = await transport(t, 100);
  for (const reset of [true, false]) {
    assert.equal((await control("write-arm", { method: "PATCH", path: "/api/v1/books/1/rating" })).status, 204);
    const outcome = fetch(`${base}/api/v1/books/1/rating`, { method: "PATCH", body: "{}" }).then(
      () => "forwarded",
      () => "cancelled",
    );
    assert.equal((await fetch(`${base}/__faults/personal-record/held`)).status, 200);
    if (reset) assert.equal((await control("reset")).status, 204);
    assert.equal(await outcome, "cancelled");
    assert.equal(requests.length, 0);
    assert.equal((await control("reset")).status, 204);
  }
});

test("proxy close unblocks and cancels a held write", async (t) => {
  const { requests, base, stop, control } = await transport(t);
  assert.equal((await control("write-arm", { method: "PATCH", path: "/api/v1/books/1/status" })).status, 204);
  const outcome = fetch(`${base}/api/v1/books/1/status`, { method: "PATCH", body: "{}" }).then(
    () => "forwarded",
    () => "cancelled",
  );
  assert.equal((await fetch(`${base}/__faults/personal-record/held`)).status, 200);
  await stop();
  assert.equal(await outcome, "cancelled");
  assert.equal(requests.length, 0);
});
