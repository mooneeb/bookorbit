import { createServer, request } from "node:http";
import { pipeline } from "node:stream/promises";
import { sanitizeLogValue } from "../../server/src/common/utils/log-sanitize.utils.ts";

const address = process.env.IPAD_PHYSICAL_HOST ?? "";
const parts = address.split(".").map(Number);
if (
  !/^\d{1,3}(?:\.\d{1,3}){3}$/.test(address) ||
  parts.some((part) => !Number.isInteger(part) || part < 0 || part > 255) ||
  !(parts[0] === 10 || (parts[0] === 172 && parts[1] >= 16 && parts[1] <= 31) || (parts[0] === 192 && parts[1] === 168))
) {
  throw new Error("IPAD_PHYSICAL_HOST must be this Mac's private IPv4 address");
}

const server = createServer((incoming, outgoing) => {
  if (!incoming.url?.startsWith("/api/v1/")) {
    incoming.resume();
    return outgoing.writeHead(404).end();
  }
  const upstream = request({
    hostname: "127.0.0.1",
    port: 16482,
    path: incoming.url,
    method: incoming.method,
    headers: { ...incoming.headers, host: "localhost:16482" },
  });
  upstream.once("response", (response) => {
    outgoing.writeHead(response.statusCode, response.headers);
    void pipeline(response, outgoing).catch(() => upstream.destroy());
  });
  upstream.once("error", () => {
    if (!outgoing.headersSent) outgoing.writeHead(502);
    outgoing.end();
  });
  outgoing.once("close", () => {
    if (!outgoing.writableFinished) upstream.destroy();
  });
  void pipeline(incoming, upstream).catch(() => upstream.destroy());
});

const startedAt = Date.now();
let closing = false;
let failed = false;
server.once("error", (error) => {
  failed = true;
  console.error(
    `[ipad.physical_fixture] [fail] port=16486 durationMs=${Date.now() - startedAt} errorClass=${error.name} error="${sanitizeLogValue(error.message)}" - private-network fixture proxy failed`,
  );
  process.exitCode = 1;
  close();
});
server.once("close", () => {
  if (!failed) {
    console.log(`[ipad.physical_fixture] [end] port=16486 durationMs=${Date.now() - startedAt} closed=true - private-network fixture proxy stopped`);
  }
});
console.log(`[ipad.physical_fixture] [start] port=16486 host="${sanitizeLogValue(address)}" - private-network fixture proxy starting`);
server.listen(16486, address);

function close() {
  if (closing) return;
  closing = true;
  server.closeAllConnections();
  server.close();
}

process.once("SIGINT", close);
process.once("SIGTERM", close);
