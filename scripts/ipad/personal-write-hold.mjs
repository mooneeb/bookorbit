export function createPersonalWriteHold({ timeoutMs = 30_000 } = {}) {
  if (!Number.isInteger(timeoutMs) || timeoutMs < 1 || timeoutMs > 30_000) throw new Error("Invalid personal write hold timeout");
  const queue = [];
  const selected = new Set();
  let current;
  let observer;
  let released = 0;
  let upstreamStatus = null;
  let generation = 0;
  const prefix = "/__faults/personal-record/";
  function observe(status, message) {
    const response = observer;
    observer = undefined;
    if (response && !response.destroyed) response.writeHead(status).end(message);
  }
  function reset() {
    generation++;
    queue.length = 0;
    selected.clear();
    current?.finish(false);
    observe(503, "cancelled");
    released = 0;
    upstreamStatus = null;
  }
  async function control(incoming, outgoing, path) {
    if (!path.startsWith(prefix)) return false;
    const action = path.slice(prefix.length);
    if (incoming.method === "GET" && action === "state") {
      outgoing.writeHead(200, { "Content-Type": "application/json", "Cache-Control": "no-store" }).end(
        JSON.stringify({
          armed: queue.length > 0,
          held: Boolean(current),
          method: current ? "PATCH" : null,
          path: current?.path ?? null,
          queuedPaths: [...queue],
          released,
          upstreamStatus,
        }),
      );
    } else if (incoming.method === "POST" && action === "write-arm") {
      let bytes = "";
      for await (const chunk of incoming) {
        bytes += chunk;
        if (Buffer.byteLength(bytes) > 512) {
          outgoing.writeHead(400).end();
          return true;
        }
      }
      let value;
      try {
        value = JSON.parse(bytes);
      } catch {
        outgoing.writeHead(400).end();
        return true;
      }
      if (
        !value ||
        Object.keys(value).some((key) => !["method", "path"].includes(key)) ||
        value.method !== "PATCH" ||
        typeof value.path !== "string" ||
        !/^\/api\/v1\/books\/[1-9][0-9]*\/(personal-note|rating|status)$/.test(value.path)
      ) {
        outgoing.writeHead(400).end();
      } else if (selected.has(value.path) || selected.size >= 3) {
        outgoing.writeHead(409).end();
      } else {
        selected.add(value.path);
        queue.push(value.path);
        outgoing.writeHead(204).end();
      }
    } else if (incoming.method === "GET" && action === "held") {
      if (current) outgoing.writeHead(200).end("held");
      else if (observer) outgoing.writeHead(409).end();
      else {
        observer = outgoing;
        const timeout = setTimeout(() => observe(504, "not held"), 15_000);
        outgoing.once("close", () => {
          clearTimeout(timeout);
          if (observer === outgoing) observer = undefined;
        });
      }
    } else if (incoming.method === "POST" && action === "release") {
      if (!current) outgoing.writeHead(409).end();
      else {
        current.finish(true);
        outgoing.writeHead(204).end();
      }
    } else if (incoming.method === "POST" && action === "reset") {
      reset();
      outgoing.writeHead(204).end();
    } else outgoing.writeHead(404).end();
    return true;
  }
  async function beforeForward(incoming, outgoing, path) {
    if (incoming.method !== "PATCH" || !queue.includes(path)) return undefined;
    if (current) {
      incoming.destroy();
      outgoing.destroy();
      return { forward: false };
    }
    queue.splice(queue.indexOf(path), 1);
    const receiptGeneration = generation;
    const forward = await new Promise((resolve) => {
      const timer = setTimeout(() => {
        queue.length = 0;
        finish(false);
      }, timeoutMs);
      function finish(allow) {
        clearTimeout(timer);
        outgoing.off("close", cancel);
        current = undefined;
        if (allow) released++;
        else {
          incoming.destroy();
          outgoing.destroy();
        }
        resolve(allow);
      }
      function cancel() {
        finish(false);
      }
      current = { path, finish };
      outgoing.once("close", cancel);
      observe(200, "held");
    });
    return {
      forward,
      recordStatus(status) {
        if (receiptGeneration === generation) upstreamStatus = status ?? null;
      },
    };
  }
  return { control, beforeForward, close: reset };
}
