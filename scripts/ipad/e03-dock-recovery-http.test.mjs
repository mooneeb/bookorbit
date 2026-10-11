import assert from "node:assert/strict";
import { test } from "node:test";
import { spawn } from "node:child_process";
import { createRequire } from "node:module";
const { PDFDocument } = createRequire(new URL("../../server/package.json", import.meta.url))("pdf-lib");

const base = process.env.IPAD_E03_API_URL ?? "http://localhost:16482/api/v1";
async function request(path, token, body, method = body ? "POST" : "GET", signal) {
  return fetch(`${base}/${path}`, {
    method,
    signal,
    headers: { ...(token ? { Authorization: `Bearer ${token}` } : {}), ...(body ? { "Content-Type": "application/json" } : {}) },
    body: body ? JSON.stringify(body) : undefined,
  });
}
async function json(path, token, body, method, signal) {
  const response = await request(path, token, body, method, signal);
  assert.ok(response.ok, `${path}: ${response.status} ${await response.clone().text()}`);
  return response.json();
}
async function login(username, signal) {
  return json(
    "auth/login",
    undefined,
    {
      username,
      password: process.env.IPAD_FIXTURE_PASSWORD ?? "IpadFixture123",
      clientKind: "native",
      deviceLabel: "Durable dock HTTP seam",
    },
    undefined,
    signal,
  );
}
async function eventually(operation, timeout = 30_000) {
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) {
    try {
      const value = await operation();
      if (value) return value;
    } catch (error) {
      if (!(error instanceof TypeError)) throw error;
    }
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  assert.fail("Durable import did not settle");
}
async function waitForRestart(child, getStartupError, getDiagnostics, timeout = 60_000, authenticate = login) {
  const deadline = Date.now() + timeout;
  let lastReadinessError;
  const checkChild = () => {
    const failure = getStartupError() ?? (child.exitCode !== null ? `Restart supervisor exited: code=${child.exitCode}` : undefined);
    if (failure) assert.fail(`${failure}\n${getDiagnostics()}`);
  };
  while (Date.now() < deadline) {
    checkChild();
    let renewed;
    try {
      renewed = await authenticate("ipad-owner", AbortSignal.timeout(Math.min(2_000, Math.max(1, deadline - Date.now()))));
    } catch (error) {
      lastReadinessError = error.message;
    }
    checkChild();
    if (renewed) return renewed;
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  assert.fail(`Restart supervisor startup timed out after ${timeout}ms: ${lastReadinessError ?? "login unavailable"}\n${getDiagnostics()}`);
}
async function scanSource(token, title) {
  const { fileName } = await json("__faults/book-dock/scanned-source", token, {});
  assert.equal((await request("book-dock/rescan", token, {})).status, 204);
  const dock = await eventually(async () => {
    const page = await json(`book-dock/files?search=${encodeURIComponent(fileName)}&page=1&limit=20`, token);
    return page.items.find((item) => item.fileName === fileName && item.status === "ready");
  });
  const caps = await json("uploads/capabilities", token);
  const library = caps.libraries.find((item) => item.name === "Fixture library") ?? caps.libraries[0];
  assert.ok(library?.folders[0]);
  await json(
    `book-dock/files/${dock.id}`,
    token,
    {
      expectedUpdatedAt: dock.updatedAt,
      selectedMetadata: { title, authors: ["Recovery fixture"] },
      targetLibraryId: library.id,
      targetFolderId: library.folders[0].id,
    },
    "PATCH",
  );
  return { dock, library };
}
async function settled(token, id) {
  return eventually(async () => {
    const job = await json(`book-dock/finalize-jobs/${id}`, token);
    return ["completed", "failed"].includes(job.state) ? job : null;
  });
}

test("IPAD-E03-A01-dock-recovery: scanned import job and retained receipt survive lost responses, reject other users and invalid roles", async () => {
  const owner = await login("ipad-owner");
  const editor = await login("ipad-editor");
  const denied = await login("ipad-reader");
  const { dock } = await scanSource(owner.accessToken, `Scanned recovery ${crypto.randomUUID()}`);
  const input = { fileIds: [dock.id], idempotencyKey: crypto.randomUUID() };
  assert.equal((await request("book-dock/finalize-jobs", denied.accessToken, input)).status, 403);
  assert.equal((await request("book-dock/finalize-jobs", owner.accessToken, { ...input, unexpected: true })).status, 400);
  // Discard the first accepted response exactly as a disconnected client would.
  assert.equal((await request("book-dock/finalize-jobs", owner.accessToken, input)).status, 202);
  const accepted = await json("book-dock/finalize-jobs", owner.accessToken, input);
  assert.equal((await request(`book-dock/finalize-jobs/${accepted.id}`, editor.accessToken)).status, 404);
  assert.equal((await request(`book-dock/finalize-jobs/${accepted.id}/retry`, editor.accessToken, {})).status, 404);
  const completed = await settled(owner.accessToken, accepted.id);
  assert.equal(completed.state, "completed", JSON.stringify(completed));
  assert.equal(completed.processed, 1);
  assert.equal(completed.succeeded, 1);
  assert.equal(completed.failed, 0);
  const imported = completed.results[0];
  assert.ok(imported.bookId);
  const replay = await json("book-dock/finalize", owner.accessToken, { fileIds: [dock.id] });
  assert.equal(replay.succeeded, 1);
  assert.equal(replay.results[0].bookId, imported.bookId);
  assert.equal((await json("book-dock/finalize-jobs", owner.accessToken, input)).id, accepted.id);
  assert.equal((await request("book-dock/finalize-jobs", owner.accessToken, { ...input, fileIds: [dock.id + 1] })).status, 409);
  assert.equal((await request(`book-dock/files/${dock.id}`, owner.accessToken)).status, 404);
  const book = await json(`books/${imported.bookId}`, owner.accessToken);
  assert.equal(book.files.length, 1);
  const collision = await scanSource(owner.accessToken, book.title);
  const blocked = await json("book-dock/finalize-jobs", owner.accessToken, { fileIds: [collision.dock.id], idempotencyKey: crypto.randomUUID() });
  const deniedCollision = await settled(owner.accessToken, blocked.id);
  assert.equal(deniedCollision.state, "failed");
  assert.equal(deniedCollision.failed, 1);
  assert.equal((await request(`book-dock/files/${collision.dock.id}`, owner.accessToken)).status, 200);
  const unchanged = await json(`books/${imported.bookId}`, owner.accessToken);
  assert.deepEqual(
    unchanged.files.map((entry) => entry.id),
    book.files.map((entry) => entry.id),
  );
  const file = await request(`books/files/${book.files[0].id}/serve`, owner.accessToken);
  assert.equal(file.status, 200);
  assert.equal(
    Buffer.from(await file.arrayBuffer())
      .subarray(0, 5)
      .toString(),
    "%PDF-",
  );
});

test("IPAD-E03-A01-dock-retry: post-commit failure resumes metadata and returns the original book identity", async () => {
  const owner = await login("ipad-owner");
  const title = `Committed recovery ${crypto.randomUUID()}`;
  const { dock, library } = await scanSource(owner.accessToken, title);
  assert.equal((await request("__faults/book-dock/arm/committed/fail", owner.accessToken, {})).status, 204);
  const accepted = await json("book-dock/finalize-jobs", owner.accessToken, { fileIds: [dock.id], idempotencyKey: crypto.randomUUID() });
  const failed = await settled(owner.accessToken, accepted.id);
  assert.equal(failed.state, "failed");
  assert.equal(failed.failed, 1);
  assert.ok(failed.results[0].message);
  assert.equal((await request(`book-dock/finalize-jobs/${accepted.id}/retry`, owner.accessToken, {})).status, 202);
  const completed = await settled(owner.accessToken, accepted.id);
  assert.equal(completed.state, "completed", JSON.stringify(completed));
  const bookId = completed.results[0].bookId;
  const book = await json(`books/${bookId}`, owner.accessToken);
  assert.equal(book.title, title);
  assert.equal(book.files.length, 1);
  const listed = await json(`libraries/${library.id}/books`, owner.accessToken, {
    pagination: { page: 0, size: 40 },
    q: title,
  });
  assert.equal(listed.items.filter((item) => item.title === title).length, 1);
  const replay = await json("book-dock/finalize", owner.accessToken, { fileIds: [dock.id] });
  assert.equal(replay.results[0].bookId, bookId);
});

test("IPAD-E03-A01-dock-upload-job: chunk receipt and queued filing share the original book after response loss", async () => {
  const owner = await login("ipad-editor");
  const token = owner.accessToken;
  const document = await PDFDocument.create();
  document.addPage([300, 400]);
  const bytes = await document.save();
  const filename = `Queued upload ${crypto.randomUUID()}.pdf`;
  const upload = await json("uploads", token, {
    filename,
    sizeBytes: bytes.length,
    idempotencyKey: crypto.randomUUID(),
    target: { kind: "book_dock" },
  });
  const body = new FormData();
  body.append("file", new Blob([bytes]), "chunk");
  assert.equal(
    (
      await fetch(`${base}/uploads/${upload.id}/chunks`, {
        method: "POST",
        headers: { Authorization: `Bearer ${token}`, "Upload-Offset": "0" },
        body,
      })
    ).status,
    201,
  );
  const completed = await json(`uploads/${upload.id}/complete`, token, {});
  const dock = await eventually(async () => {
    const entry = await json(`book-dock/files/${completed.bookDockFileId}`, token);
    return entry.status === "ready" ? entry : null;
  });
  const caps = await json("uploads/capabilities", token);
  const library = caps.libraries.find((item) => item.name === "Fixture library") ?? caps.libraries[0];
  await json(
    `book-dock/files/${dock.id}`,
    token,
    {
      expectedUpdatedAt: dock.updatedAt,
      selectedMetadata: { title: filename, authors: ["Queued upload"] },
      targetLibraryId: library.id,
      targetFolderId: library.folders[0].id,
    },
    "PATCH",
  );
  const input = { fileIds: [dock.id], idempotencyKey: crypto.randomUUID() };
  await request("book-dock/finalize-jobs", token, input);
  const accepted = await json("book-dock/finalize-jobs", token, input);
  const result = await settled(token, accepted.id);
  assert.equal(result.state, "completed", JSON.stringify(result));
  const receipt = await json(`uploads/${upload.id}`, token);
  assert.equal(receipt.bookId, result.results[0].bookId);
  const replay = await json("book-dock/finalize", token, { fileIds: [dock.id] });
  assert.equal(replay.results[0].bookId, receipt.bookId);
  const book = await json(`books/${receipt.bookId}`, token);
  assert.equal(book.files.length, 1);
  const served = await request(`books/files/${book.files[0].id}/serve`, token);
  assert.equal(served.status, 200);
  assert.deepEqual(new Uint8Array(await served.arrayBuffer()), new Uint8Array(bytes));
});

for (const phase of ["published", "committed"]) {
  test(
    `IPAD-E03-A01-dock-crash-${phase}: startup resumes accepted intent with one readable book`,
    { skip: !process.env.IPAD_E03_RECOVERY_RUN_ID },
    async () => {
      const owner = await login("ipad-owner");
      const title = `Process recovery ${phase} ${crypto.randomUUID()}`;
      const { dock } = await scanSource(owner.accessToken, title);
      await request(`__faults/book-dock/arm/${phase}/crash`, owner.accessToken, {});
      const input = { fileIds: [dock.id], idempotencyKey: crypto.randomUUID() };
      try {
        await request("book-dock/finalize-jobs", owner.accessToken, input);
      } catch (error) {
        assert.ok(error instanceof TypeError);
      }
      await eventually(async () => {
        try {
          await request("auth/me", owner.accessToken);
          return null;
        } catch {
          return true;
        }
      });
      const child = spawn(
        process.execPath,
        ["scripts/ipad/restart-server.mjs", process.env.IPAD_E03_RECOVERY_RUN_ID, "--allow-stopped", "--skip-build"],
        { detached: true, stdio: ["ignore", "ignore", "pipe"], env: process.env },
      );
      let diagnostics = "";
      let startupError;
      const collectDiagnostics = (chunk) => {
        diagnostics = (diagnostics + chunk.toString()).slice(-8192);
      };
      const recordError = (error) => {
        startupError = `Restart supervisor spawn failed: ${error.message}`;
      };
      const recordExit = (code, signal) => {
        startupError = `Restart supervisor exited: code=${code} signal=${signal ?? "none"}`;
      };
      child.stderr.on("data", collectDiagnostics);
      child.on("error", recordError);
      child.on("exit", recordExit);
      try {
        const renewed = await waitForRestart(
          child,
          () => startupError,
          () => diagnostics,
        );
        const accepted = await json("book-dock/finalize-jobs", renewed.accessToken, input);
        const completed = await settled(renewed.accessToken, accepted.id);
        assert.equal(completed.state, "completed", JSON.stringify(completed));
        assert.equal(completed.succeeded, 1);
        const book = await json(`books/${completed.results[0].bookId}`, renewed.accessToken);
        assert.equal(book.title, title);
        assert.equal(book.files.length, 1);
        assert.equal((await request(`books/files/${book.files[0].id}/serve`, renewed.accessToken)).status, 200);
        const receipt = await json("book-dock/finalize", renewed.accessToken, { fileIds: [dock.id] });
        assert.equal(receipt.results[0].bookId, book.id);
      } finally {
        child.stderr.off("data", collectDiagnostics);
        child.stderr.destroy();
        child.unref();
      }
    },
  );
}
