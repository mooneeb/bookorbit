import assert from "node:assert/strict";
import { createServer } from "node:http";
import test from "node:test";
import { startFaultProxy } from "./fault-proxy.mjs";

test("controlled reading-attempt receipt drops only after upstream completes, then forwards retry", async (t) => {
  let commits = 0;
  const upstream = createServer(async (incoming, outgoing) => {
    for await (const _ of incoming) {
      /* Drain the transport request. */
    }
    commits++;
    outgoing.writeHead(incoming.method === "PATCH" ? 200 : 201, { "Content-Type": "application/json" }).end(JSON.stringify({ id: 1 }));
  });
  await new Promise((resolve) => upstream.listen(0, "127.0.0.1", resolve));
  const stop = await startFaultProxy({ port: 0, upstreamPort: upstream.address().port });
  t.after(async () => {
    await stop();
    await new Promise((resolve) => upstream.close(resolve));
  });
  const base = `http://127.0.0.1:${stop.port}`;
  const armed = await fetch(`${base}/__faults/reading-attempt/drop-next-receipt`, { method: "POST" });
  assert.equal(armed.status, 204);
  await assert.rejects(fetch(`${base}/api/v1/books/1/reading-attempts`, { method: "POST", body: "{}" }));
  assert.equal(commits, 1);
  const status = await (await fetch(`${base}/__faults/reading-attempt/receipt`)).json();
  assert.deepEqual(status, { armed: false, dropped: 1, upstreamStatus: 201 });
  const retry = await fetch(`${base}/api/v1/books/1/reading-attempts`, { method: "POST", body: "{}" });
  assert.equal(retry.status, 201);
  assert.deepEqual(await retry.json(), { id: 1 });
  assert.equal(commits, 2);
  const patchArm = await fetch(`${base}/__faults/reading-attempt/drop-next-receipt`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ method: "PATCH" }),
  });
  assert.equal(patchArm.status, 204);
  await assert.rejects(fetch(`${base}/api/v1/books/1/reading-attempts/1`, { method: "PATCH", body: "{}" }));
  assert.equal(commits, 3);
  const patchStatus = await (await fetch(`${base}/__faults/reading-attempt/receipt`)).json();
  assert.deepEqual(patchStatus, { armed: false, dropped: 2, upstreamStatus: 200 });
});
