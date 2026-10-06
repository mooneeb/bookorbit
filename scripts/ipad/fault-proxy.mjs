import { createServer, request } from "node:http";
import { pipeline } from "node:stream/promises";

export async function startFaultProxy() {
  let organizationUnavailable = false;
  let armed = false;
  let release;
  let held = false;
  let observer;
  let progressUnavailable = false;
  let snapshotArmed = false;
  let writeArmed = false;
  let snapshotGeneration = 0;
  let coverArmed = false;
  let coverPending = false;
  let coverHeld = false;
  let coverRelease;
  let coverObserver;
  let coverUploadsUnavailable = false;
  let coverSnapshotUnavailable = false;
  const server = createServer(async (incoming, outgoing) => {
    const path = new URL(incoming.url, "http://localhost:16485").pathname;
    if (path.startsWith("/__faults/")) {
      if (incoming.method === "POST" && ["/__faults/organization/fail", "/__faults/organization/recover"].includes(path)) {
        organizationUnavailable = path.endsWith("/fail");
        return outgoing.writeHead(204).end();
      }
      if (incoming.method === "POST" && ["/__faults/cover/upload-fail", "/__faults/cover/upload-recover"].includes(path)) {
        coverUploadsUnavailable = path.endsWith("upload-fail");
        return outgoing.writeHead(204).end();
      }
      if (incoming.method === "POST" && ["/__faults/cover/snapshot-fail", "/__faults/cover/snapshot-recover"].includes(path)) {
        coverSnapshotUnavailable = path.endsWith("snapshot-fail");
        return outgoing.writeHead(204).end();
      }
      if (incoming.method === "POST" && path === "/__faults/cover/arm") {
        if (coverArmed || coverPending) return outgoing.writeHead(409).end();
        coverArmed = true;
        return outgoing.writeHead(204).end();
      }
      if (incoming.method === "POST" && path === "/__faults/cover/release") {
        if (!coverHeld || !coverRelease) return outgoing.writeHead(409).end();
        await coverRelease();
        return outgoing.writeHead(204).end();
      }
      if (incoming.method === "GET" && path === "/__faults/cover/held") {
        if (coverHeld) return outgoing.writeHead(200).end("held");
        if (coverObserver) return outgoing.writeHead(409).end();
        coverObserver = outgoing;
        const timeout = setTimeout(() => outgoing.writeHead(504).end(), 10_000);
        outgoing.once("close", () => {
          clearTimeout(timeout);
          if (coverObserver === outgoing) coverObserver = undefined;
        });
        return;
      }
      if (incoming.method === "POST" && path === "/__faults/progress/fail") {
        progressUnavailable = true;
        return outgoing.writeHead(204).end();
      }
      if (incoming.method === "POST" && path === "/__faults/progress/recover") {
        progressUnavailable = false;
        return outgoing.writeHead(204).end();
      }
      if (incoming.method === "POST" && path === "/__faults/progress/arm") {
        if (armed || snapshotArmed || writeArmed || held) return outgoing.writeHead(409).end();
        armed = true;
        return outgoing.writeHead(204).end();
      }
      if (incoming.method === "POST" && path === "/__faults/progress/snapshot-arm") {
        if (armed || snapshotArmed || writeArmed || held) return outgoing.writeHead(409).end();
        snapshotArmed = true;
        return outgoing.writeHead(204).end();
      }
      if (incoming.method === "POST" && path === "/__faults/progress/write-arm") {
        if (armed || snapshotArmed || writeArmed || held) return outgoing.writeHead(409).end();
        writeArmed = true;
        return outgoing.writeHead(204).end();
      }
      if (incoming.method === "POST" && path === "/__faults/progress/snapshot-reset") {
        armed = false;
        snapshotArmed = false;
        writeArmed = false;
        snapshotGeneration++;
        release?.();
        return outgoing.writeHead(204).end();
      }
      if (incoming.method === "POST" && path === "/__faults/progress/release") {
        if (!held || !release) return outgoing.writeHead(409).end();
        release();
        return outgoing.writeHead(204).end();
      }
      if (incoming.method === "GET" && path === "/__faults/progress/held") {
        if (held) return outgoing.writeHead(200).end("held");
        if (observer) return outgoing.writeHead(409).end();
        observer = outgoing;
        const timeout = setTimeout(() => outgoing.writeHead(504).end(), 10_000);
        outgoing.once("close", () => {
          clearTimeout(timeout);
          if (observer === outgoing) observer = undefined;
        });
        return;
      }
      return outgoing.writeHead(404).end();
    }
    if (
      (coverUploadsUnavailable && incoming.method === "POST" && path === "/api/v1/books/6/cover") ||
      (coverSnapshotUnavailable && incoming.method === "GET" && path === "/api/v1/books/6")
    ) {
      incoming.resume();
      return outgoing.writeHead(503).end();
    }
    if (progressUnavailable && path === "/api/v1/books/files/1/progress") {
      return outgoing.writeHead(503).end();
    }
    if (
      (armed && incoming.method === "GET" && path === "/api/v1/books/files/1/progress") ||
      (writeArmed && incoming.method === "POST" && /^\/api\/v1\/books\/files\/[12]\/progress$/.test(path))
    ) {
      armed = false;
      writeArmed = false;
      held = true;
      observer?.writeHead(200).end("held");
      await new Promise((resolve) => {
        const timeout = setTimeout(finish, 30_000);
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
      if (outgoing.destroyed) return;
    }
    if (organizationUnavailable && incoming.method === "GET" && /^\/api\/v1\/(authors|series)(\/|$)/.test(path)) {
      return outgoing
        .writeHead(503, { "Content-Type": "application/json" })
        .end(JSON.stringify({ message: "Organization fixture temporarily unavailable" }));
    }
    const holdCover =
      coverArmed &&
      incoming.method === "GET" &&
      path === "/api/v1/books/6/cover" &&
      new URL(incoming.url, "http://localhost:16485").searchParams.get("medium") === "ebook";
    const holdProgress = snapshotArmed && incoming.method === "GET" && /^\/api\/v1\/books\/files\/[12]\/progress$/.test(path);
    const progressGeneration = snapshotGeneration;
    if (holdProgress) snapshotArmed = false;
    if (holdCover) {
      coverArmed = false;
      coverPending = true;
    }
    const upstream = request({
      hostname: "localhost",
      port: 16482,
      path: incoming.url,
      method: incoming.method,
      headers: { ...incoming.headers, host: "localhost:16482" },
    });
    upstream.once("response", async (response) => {
      if (holdProgress) {
        try {
          const chunks = [];
          let size = 0;
          for await (const chunk of response) {
            size += chunk.length;
            if (size > 64 * 1024) throw new Error("Progress fault snapshot exceeds its response limit");
            chunks.push(chunk);
          }
          const bytes = Buffer.concat(chunks);
          if (response.statusCode !== 200 || bytes.length < 2) throw new Error("Progress fault requires a real successful response");
          outgoing.writeHead(response.statusCode, response.headers);
          if (progressGeneration !== snapshotGeneration) return outgoing.end(bytes);
          outgoing.write(bytes.subarray(0, 1));
          held = true;
          observer?.writeHead(200).end("held");
          await new Promise((resolve) => {
            const timeout = setTimeout(finish, 30_000);
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
          if (!outgoing.destroyed) outgoing.end(bytes.subarray(1));
        } catch {
          if (!outgoing.headersSent) outgoing.writeHead(502);
          outgoing.end();
        }
        return;
      }
      if (holdCover) {
        try {
          const chunks = [];
          let size = 0;
          for await (const chunk of response) {
            size += chunk.length;
            if (size > 20 * 1024 * 1024) throw new Error("Cover fault snapshot exceeds the artifact limit");
            chunks.push(chunk);
          }
          const bytes = Buffer.concat(chunks);
          if (response.statusCode !== 200 || bytes.length < 2) throw new Error("Cover fault requires a real successful image response");
          outgoing.writeHead(response.statusCode, response.headers);
          outgoing.write(bytes.subarray(0, 1));
          let forwardedBytes = 1;
          coverHeld = true;
          coverObserver?.writeHead(200).end("held");
          const forwarded = new Promise((resolve) => {
            outgoing.once("finish", resolve);
            outgoing.once("close", resolve);
          });
          await new Promise((resolve) => {
            const keepStreaming = setInterval(() => {
              if (!outgoing.destroyed && forwardedBytes < bytes.length - 1) {
                outgoing.write(bytes.subarray(forwardedBytes, forwardedBytes + 1));
                forwardedBytes++;
              }
            }, 5_000);
            const timeout = setTimeout(finish, 45_000);
            function finish() {
              clearTimeout(timeout);
              clearInterval(keepStreaming);
              outgoing.off("close", finish);
              coverHeld = false;
              coverRelease = undefined;
              resolve();
            }
            coverRelease = async () => {
              finish();
              await forwarded;
            };
            outgoing.once("close", finish);
          });
          if (!outgoing.destroyed) outgoing.end(bytes.subarray(forwardedBytes));
        } catch {
          if (!outgoing.headersSent) outgoing.writeHead(502);
          outgoing.end();
        } finally {
          coverPending = false;
          coverHeld = false;
          coverRelease = undefined;
        }
        return;
      }
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
  await new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(16485, "127.0.0.1", resolve);
  });
  return async () => {
    armed = false;
    snapshotArmed = false;
    writeArmed = false;
    snapshotGeneration++;
    release?.();
    observer?.writeHead(503).end();
    coverArmed = false;
    void coverRelease?.();
    coverObserver?.writeHead(503).end();
    server.closeAllConnections();
    await new Promise((resolve, reject) => server.close((error) => (error ? reject(error) : resolve())));
  };
}
