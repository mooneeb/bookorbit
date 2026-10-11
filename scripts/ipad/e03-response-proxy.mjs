import { createServer, request } from "node:http";
import { pipeline } from "node:stream/promises";

export async function startE03ResponseProxy({ port = 16488, upstreamPort = 16482, seedDock } = {}) {
  let armed = false;
  let held = false;
  let release;
  let acquisition = { armed: false, held: false, sessionId: null, offset: null };
  let releaseUpload;
  let cutUpload;
  const sockets = new Set();
  const server = createServer(async (incoming, outgoing) => {
    const path = new URL(incoming.url, "http://localhost").pathname;
    if (path.startsWith("/__faults/acquisition/")) {
      const action = path.slice("/__faults/acquisition/".length);
      if (action === "held" && incoming.method === "GET") {
        return outgoing.writeHead(200, { "content-type": "application/json", "cache-control": "no-store" }).end(JSON.stringify(acquisition));
      }
      if (action === "arm" && incoming.method === "POST") {
        if (acquisition.armed || acquisition.held) return outgoing.writeHead(409).end();
        acquisition = { armed: true, held: false, sessionId: null, offset: null };
        return outgoing.writeHead(204).end();
      }
      if (["release", "cut", "reset"].includes(action) && incoming.method === "POST") {
        acquisition.armed = false;
        if (action === "release") releaseUpload?.();
        else cutUpload?.();
        if (action === "reset") acquisition = { armed: false, held: false, sessionId: null, offset: null };
        return outgoing.writeHead(204).end();
      }
      if (action === "seed-dock" && incoming.method === "POST" && seedDock) {
        try {
          const result = await seedDock();
          return outgoing.writeHead(200, { "content-type": "application/json", "cache-control": "no-store" }).end(JSON.stringify(result));
        } catch {
          return outgoing.writeHead(502).end();
        }
      }
      return outgoing.writeHead(404).end();
    }
    if (path.startsWith("/__faults/bulk/")) {
      const action = path.slice("/__faults/bulk/".length);
      if (action === "arm" && incoming.method === "POST") {
        if (armed || held) return outgoing.writeHead(409).end();
        armed = true;
        return outgoing.writeHead(204).end();
      }
      if (action === "held" && incoming.method === "GET") {
        return outgoing.writeHead(200, { "content-type": "application/json", "cache-control": "no-store" }).end(JSON.stringify({ armed, held }));
      }
      if (action === "release" && incoming.method === "POST") {
        armed = false;
        release?.();
        return outgoing.writeHead(204).end();
      }
      return outgoing.writeHead(404).end();
    }
    const chunk = path.match(/^\/api\/v1\/uploads\/([0-9a-f-]+)\/chunks$/i);
    const offset = Number(incoming.headers["upload-offset"]);
    if (acquisition.armed && incoming.method === "POST" && chunk && Number.isSafeInteger(offset) && offset > 0) {
      acquisition = { armed: false, held: true, sessionId: chunk[1], offset };
      await new Promise((resolve) => {
        const timeout = setTimeout(finish, 45_000);
        function finish() {
          clearTimeout(timeout);
          outgoing.off("close", finish);
          acquisition.held = false;
          releaseUpload = undefined;
          cutUpload = undefined;
          resolve();
        }
        releaseUpload = finish;
        cutUpload = () => {
          outgoing.destroy();
          finish();
        };
        outgoing.once("close", finish);
      });
      if (outgoing.destroyed) return;
    }
    const holdResponse = armed && incoming.method === "POST" && path === "/api/v1/books/bulk-edit-metadata";
    if (holdResponse) armed = false;
    const upstream = request(
      {
        hostname: "127.0.0.1",
        port: upstreamPort,
        path: incoming.url,
        method: incoming.method,
        headers: { ...incoming.headers, host: `localhost:${upstreamPort}` },
      },
      async (response) => {
        if (holdResponse && response.statusCode >= 200 && response.statusCode < 300) {
          held = true;
          await new Promise((resolve) => {
            const timeout = setTimeout(finish, 45_000);
            function finish() {
              clearTimeout(timeout);
              outgoing.off("close", finish);
              held = false;
              release = undefined;
              resolve();
            }
            release = finish;
            outgoing.once("close", finish);
          });
        }
        if (outgoing.destroyed) {
          response.destroy();
          return;
        }
        outgoing.writeHead(response.statusCode, response.headers);
        try {
          await pipeline(response, outgoing);
        } catch {
          outgoing.destroy();
        }
      },
    );
    upstream.once("error", () => {
      if (!outgoing.headersSent) outgoing.writeHead(502).end();
      else outgoing.destroy();
    });
    incoming.once("aborted", () => upstream.destroy());
    outgoing.once("close", () => upstream.destroy());
    incoming.pipe(upstream);
  });
  server.on("connection", (socket) => {
    sockets.add(socket);
    socket.once("close", () => sockets.delete(socket));
  });
  await new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(port, "127.0.0.1", resolve);
  });
  return {
    origin: `http://127.0.0.1:${server.address().port}`,
    close: async () => {
      release?.();
      cutUpload?.();
      for (const socket of sockets) socket.destroy();
      await new Promise((resolve, reject) => server.close((error) => (error ? reject(error) : resolve())));
    },
  };
}
