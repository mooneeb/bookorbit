import { createServer, request } from "node:http";
import { pipeline } from "node:stream/promises";

export async function startFaultProxy({ captureProgressCAS = false, port = 16485 } = {}) {
  let annotationOffline = false;
  let annotationWriteArmed = false;
  let annotationTransferPath;
  let annotationHeld = false;
  let annotationRelease;
  let annotationObserver;
  let annotationHeldResponse;
  const annotationCheckpoints = new Set();
  let annotationTraffic = [];
  let annotationTrafficTruncated = false;
  async function holdAnnotation(outgoing) {
    annotationHeld = true;
    annotationHeldResponse = outgoing;
    annotationObserver?.writeHead(200).end("held");
    await new Promise((resolve) => {
      const timeout = setTimeout(finish, 45_000);
      function finish() {
        clearTimeout(timeout);
        outgoing.off("close", finish);
        annotationHeld = false;
        annotationHeldResponse = undefined;
        annotationRelease = undefined;
        resolve();
      }
      annotationRelease = finish;
      outgoing.once("close", finish);
    });
  }
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
  let comicFileID;
  let comicCountUnavailable = false;
  let comicPagesUnavailable = false;
  let comicProgressUnavailable = false;
  let comicWriteArmed = false;
  const server = createServer(async (incoming, outgoing) => {
    const path = new URL(incoming.url, "http://localhost:16485").pathname;
    if (path.startsWith("/__faults/")) {
      if (path.startsWith("/__faults/annotations/")) {
        const action = path.slice("/__faults/annotations/".length);
        if (action === "traffic" && incoming.method === "GET") {
          return outgoing
            .writeHead(200, { "Content-Type": "application/json", "Cache-Control": "no-store" })
            .end(JSON.stringify({ items: annotationTraffic, truncated: annotationTrafficTruncated }));
        }
        const checkpoint = action.match(/^checkpoint\/([a-z0-9-]+)$/);
        if (checkpoint && incoming.method === "POST") {
          annotationCheckpoints.add(checkpoint[1]);
          return outgoing.writeHead(204).end();
        }
        if (checkpoint && incoming.method === "GET") {
          return outgoing
            .writeHead(200, { "Content-Type": "application/json", "Cache-Control": "no-store" })
            .end(JSON.stringify({ reached: annotationCheckpoints.has(checkpoint[1]) }));
        }
        if (incoming.method === "POST" && ["offline", "online", "reset"].includes(action)) {
          annotationOffline = action === "offline";
          if (action === "reset") {
            annotationCheckpoints.clear();
            annotationTraffic = [];
            annotationTrafficTruncated = false;
            annotationWriteArmed = false;
            annotationTransferPath = undefined;
            annotationRelease?.();
          }
          return outgoing.writeHead(204).end();
        }
        if (incoming.method === "POST" && action === "write-arm") {
          if (annotationHeld || annotationWriteArmed) return outgoing.writeHead(409).end();
          annotationWriteArmed = true;
          return outgoing.writeHead(204).end();
        }
        if (incoming.method === "POST" && action === "transfer-arm") {
          const target = new URL(incoming.url, "http://localhost:16485").searchParams.get("path");
          if (!target || !/^\/api\/v1\/(?:books\/files\/[1-9][0-9]*\/(?:serve|download)|epub\/|cbz\/|audio\/)/.test(target)) {
            return outgoing.writeHead(400).end();
          }
          if (annotationHeld || annotationTransferPath) return outgoing.writeHead(409).end();
          annotationTransferPath = target;
          return outgoing.writeHead(204).end();
        }
        if (incoming.method === "POST" && ["release", "cut"].includes(action)) {
          if (!annotationHeld || !annotationRelease) return outgoing.writeHead(409).end();
          if (action === "cut") annotationHeldResponse?.destroy();
          annotationRelease();
          return outgoing.writeHead(204).end();
        }
        if (incoming.method === "GET" && action === "held") {
          if (annotationHeld) return outgoing.writeHead(200).end("held");
          if (annotationObserver) return outgoing.writeHead(409).end();
          annotationObserver = outgoing;
          const timeout = setTimeout(() => outgoing.writeHead(504).end(), 15_000);
          outgoing.once("close", () => {
            clearTimeout(timeout);
            if (annotationObserver === outgoing) annotationObserver = undefined;
          });
          return;
        }
        return outgoing.writeHead(404).end();
      }
      if (incoming.method === "POST" && ["/__faults/organization/fail", "/__faults/organization/recover"].includes(path)) {
        organizationUnavailable = path.endsWith("/fail");
        return outgoing.writeHead(204).end();
      }
      const comicControl = path.match(
        /^\/__faults\/comic\/([1-9][0-9]*)\/(count-fail|count-recover|pages-fail|pages-recover|progress-fail|progress-recover|write-arm|reset)$/,
      );
      if (incoming.method === "POST" && comicControl) {
        comicFileID = Number(comicControl[1]);
        const operation = comicControl[2];
        if (operation === "count-fail") comicCountUnavailable = true;
        if (operation === "count-recover") comicCountUnavailable = false;
        if (operation === "pages-fail") comicPagesUnavailable = true;
        if (operation === "pages-recover") comicPagesUnavailable = false;
        if (operation === "progress-fail") comicProgressUnavailable = true;
        if (operation === "progress-recover") comicProgressUnavailable = false;
        if (operation === "write-arm") {
          if (armed || snapshotArmed || writeArmed || comicWriteArmed || held) return outgoing.writeHead(409).end();
          comicWriteArmed = true;
        }
        if (operation === "reset") {
          comicCountUnavailable = false;
          comicPagesUnavailable = false;
          comicProgressUnavailable = false;
          comicWriteArmed = false;
          release?.();
        }
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
    const traffic = {
      path: path.slice(0, 2048),
      method: incoming.method,
      range: incoming.headers.range?.slice(0, 256) ?? null,
      status: null,
      bytes: 0,
      complete: false,
    };
    const captureProgress = captureProgressCAS && path === "/api/v1/books/files/2/progress";
    function captureJSON(stream, field, keys) {
      const chunks = [];
      let size = 0;
      stream.on("data", (chunk) => {
        size += chunk.length;
        if (size <= 16 * 1024) chunks.push(Buffer.from(chunk));
        else chunks.length = 0;
      });
      stream.once("end", () => {
        if (size > 16 * 1024) {
          traffic[field] = { omitted: "size_limit" };
          return;
        }
        try {
          const value = JSON.parse(Buffer.concat(chunks).toString("utf8"));
          const selected = {};
          for (const key of keys) {
            const item = value[key];
            if (key.endsWith("Version")) {
              if (item === null || (typeof item === "string" && /^[a-f0-9]{64}$/.test(item))) selected[key] = item;
            } else if (key === "source") {
              if (item === "text" || item === "narration") selected[key] = item;
            } else if (typeof item === "number" && Number.isFinite(item)) selected[key] = item;
          }
          if (field === "progressResponse" && stream.statusCode === 409) {
            if (value.statusCode === 409) selected.statusCode = 409;
            if (value.error === "Conflict") selected.error = value.error;
            if (value.message === "Reading position changed in another reader") selected.message = value.message;
          }
          traffic[field] = selected;
        } catch {
          traffic[field] = { omitted: "invalid_json" };
        }
      });
    }
    annotationTraffic.push(traffic);
    if (annotationTraffic.length > 512) {
      annotationTraffic.shift();
      annotationTrafficTruncated = true;
    }
    const write = outgoing.write;
    const end = outgoing.end;
    function countBytes(chunk, encoding) {
      if (typeof chunk === "string") traffic.bytes += Buffer.byteLength(chunk, typeof encoding === "string" ? encoding : "utf8");
      else if (chunk && ArrayBuffer.isView(chunk)) traffic.bytes += chunk.byteLength;
    }
    outgoing.write = function (chunk, ...args) {
      countBytes(chunk, args[0]);
      return write.call(this, chunk, ...args);
    };
    outgoing.end = function (chunk, ...args) {
      countBytes(chunk, args[0]);
      return end.call(this, chunk, ...args);
    };
    outgoing.once("finish", () => {
      traffic.status = outgoing.statusCode;
      traffic.complete = true;
    });
    outgoing.once("close", () => {
      traffic.status = outgoing.headersSent ? outgoing.statusCode : null;
    });
    if (annotationOffline && path.startsWith("/api/v1/")) {
      incoming.resume();
      outgoing.destroy();
      return;
    }
    if (
      annotationWriteArmed &&
      incoming.method === "POST" &&
      (path === "/api/v1/annotations/native/operations" ||
        /^\/api\/v1\/annotations\/native\/source-ink\/[1-9][0-9]*\/[1-9][0-9]*\/operations$/.test(path))
    ) {
      annotationWriteArmed = false;
      await holdAnnotation(outgoing);
      if (outgoing.destroyed) return;
    }
    const holdAnnotationTransfer = incoming.method === "GET" && path === annotationTransferPath;
    if (holdAnnotationTransfer) annotationTransferPath = undefined;
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
      (comicCountUnavailable && path === `/api/v1/cbz/files/${comicFileID}/pages`) ||
      (comicPagesUnavailable && path.startsWith(`/api/v1/cbz/files/${comicFileID}/pages/`)) ||
      (comicProgressUnavailable && incoming.method === "POST" && path === `/api/v1/books/files/${comicFileID}/progress`)
    ) {
      incoming.resume();
      return outgoing.writeHead(503).end();
    }
    if (
      (armed && incoming.method === "GET" && path === "/api/v1/books/files/1/progress") ||
      (writeArmed && incoming.method === "POST" && /^\/api\/v1\/books\/files\/[12]\/progress$/.test(path)) ||
      (comicWriteArmed && incoming.method === "POST" && path === `/api/v1/books/files/${comicFileID}/progress`)
    ) {
      armed = false;
      writeArmed = false;
      comicWriteArmed = false;
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
      if (captureProgress && (incoming.method === "GET" || response.statusCode === 409)) {
        captureJSON(response, "progressResponse", ["textVersion", "narrationVersion", "percentage"]);
      }
      if (holdAnnotationTransfer && response.statusCode && response.statusCode >= 200 && response.statusCode < 300) {
        outgoing.writeHead(response.statusCode, response.headers);
        let first = true;
        try {
          for await (const chunk of response) {
            if (first) {
              first = false;
              outgoing.write(chunk.subarray(0, 1));
              await holdAnnotation(outgoing);
              if (outgoing.destroyed) return;
              if (chunk.length > 1) outgoing.write(chunk.subarray(1));
            } else if (!outgoing.write(chunk)) {
              await new Promise((resolve) => outgoing.once("drain", resolve));
            }
          }
          outgoing.end();
        } catch {
          outgoing.destroy();
        }
        return;
      }
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
    if (captureProgress && incoming.method === "POST") {
      captureJSON(incoming, "progressRequest", ["baseVersion", "baseNarrationVersion", "source", "percentage"]);
    }
    void pipeline(incoming, upstream).catch(() => upstream.destroy());
  });
  await new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(port, "127.0.0.1", resolve);
  });
  return async () => {
    annotationRelease?.();
    annotationObserver?.writeHead(503).end();
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
