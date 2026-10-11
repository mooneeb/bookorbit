import assert from "node:assert/strict";
import { createServer } from "node:http";
import test from "node:test";
import { startFaultProxy } from "./fault-proxy.mjs";

test("privacy save fault is one-shot and leaves reads, auth, other writes and retry untouched", async (t) => {
  const requests = [];
  const upstream = createServer(async (incoming, outgoing) => {
    const chunks = [];
    for await (const chunk of incoming) chunks.push(chunk);
    requests.push({
      method: incoming.method,
      path: incoming.url,
      authorization: incoming.headers.authorization,
      body: Buffer.concat(chunks).toString("utf8"),
    });
    outgoing.writeHead(200, { "Content-Type": "application/json", "X-E04-Upstream": "transport" }).end(JSON.stringify({ fixture: "upstream echo" }));
  });
  await new Promise((resolve) => upstream.listen(0, "127.0.0.1", resolve));
  const stop = await startFaultProxy({ port: 0, upstreamPort: upstream.address().port });
  t.after(async () => {
    await stop();
    upstream.closeAllConnections();
    await new Promise((resolve) => upstream.close(resolve));
  });
  const base = `http://127.0.0.1:${stop.port}`;
  const privacy = "/api/v1/reading-insights-sharing/me";
  async function control(action) {
    return fetch(`${base}/__faults/privacy-sharing/${action}`, { method: "POST" });
  }
  async function state() {
    const response = await fetch(`${base}/__faults/privacy-sharing/state`);
    assert.equal(response.status, 200);
    return response.json();
  }
  assert.deepEqual(await state(), { armed: false, failed: 0 });
  assert.equal((await control("fail-next-patch")).status, 204);
  assert.equal((await control("fail-next-patch")).status, 409);
  const authorization = "Bearer fixture-transport-only";
  for (const [method, path] of [
    ["GET", privacy],
    ["POST", "/api/v1/auth/login"],
    ["PATCH", "/api/v1/books/1/rating"],
    ["PATCH", `${privacy}/other`],
  ]) {
    const response = await fetch(`${base}${path}`, { method, headers: { Authorization: authorization } });
    assert.equal(response.status, 200);
    assert.equal(response.headers.get("x-e04-upstream"), "transport");
    await response.arrayBuffer();
  }
  assert.deepEqual(await state(), { armed: true, failed: 0 });
  const body = JSON.stringify({ fixture: "unchanged privacy request" });
  const options = { method: "PATCH", headers: { Authorization: authorization, "Content-Type": "application/json" }, body };
  const failure = await fetch(`${base}${privacy}`, options);
  assert.equal(failure.status, 503);
  assert.equal(failure.headers.get("cache-control"), "no-store");
  assert.deepEqual(await failure.json(), { message: "Reading insights sharing temporarily unavailable" });
  assert.equal(requests.length, 4, "controlled failure never reached upstream");
  assert.deepEqual(await state(), { armed: false, failed: 1 });
  const retry = await fetch(`${base}${privacy}`, options);
  assert.equal(retry.status, 200);
  assert.equal(retry.headers.get("x-e04-upstream"), "transport");
  await retry.arrayBuffer();
  assert.deepEqual(requests.at(-1), { method: "PATCH", path: privacy, authorization, body });
  assert.deepEqual(await state(), { armed: false, failed: 1 });
  const traffic = await (await fetch(`${base}/__faults/annotations/traffic`)).json();
  assert.deepEqual(
    traffic.items.filter((entry) => entry.path === privacy && entry.method === "PATCH").map((entry) => entry.status),
    [503, 200],
  );
  assert.equal((await control("fail-next-patch")).status, 204);
  assert.equal((await control("reset")).status, 204);
  assert.deepEqual(await state(), { armed: false, failed: 0 });
  const afterReset = await fetch(`${base}${privacy}`, options);
  assert.equal(afterReset.status, 200);
  await afterReset.arrayBuffer();
});
