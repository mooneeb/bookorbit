import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { mkdir, readFile, readdir, rm, writeFile } from "node:fs/promises";
import { createRequire } from "node:module";
import { join } from "node:path";
import { test } from "node:test";

const require = createRequire(new URL("../../server/package.json", import.meta.url));
const sharp = require("sharp");
const base = process.env.IPAD_API_BASE ?? "http://localhost:16482/api/v1";

test("IPAD-E03-A05-preservation: merging a covered book retains cover bytes and Kobo identity and private state", async () => {
  const { preservation: pair } = JSON.parse(await readFile(process.env.IPAD_MERGE_FIXTURE, "utf8"));
  assert.ok(pair, "Dedicated preservation fixture is required");
  const login = await fetch(`${base}/auth/login`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ username: "ipad-owner", password: "IpadFixture123", clientKind: "native", deviceLabel: "E03 preservation" }),
  });
  assert.equal(login.status, 200);
  const session = await login.json();
  const headers = { Authorization: `Bearer ${session.accessToken}` };
  const post = async (path, body) => {
    const response = await fetch(`${base}/${path}`, {
      method: "POST",
      headers: { ...headers, "Content-Type": "application/json" },
      body: JSON.stringify(body),
    });
    assert.ok(response.ok, `${path}: ${response.status} ${await response.clone().text()}`);
    return response.json();
  };
  try {
    const cover = await sharp({ create: { width: 60, height: 90, channels: 3, background: { r: 40, g: 120, b: 200 } } })
      .jpeg()
      .toBuffer();
    const form = new FormData();
    form.set("file", new Blob([cover], { type: "image/jpeg" }), "preserved-cover.jpg");
    const upload = await fetch(`${base}/books/${pair.sourceBookId}/cover?medium=ebook`, { method: "POST", headers, body: form });
    assert.equal(upload.status, 204, await upload.text());
    const before = await fetch(`${base}/books/${pair.sourceBookId}/cover?medium=ebook`, { headers });
    assert.ok(before.ok);
    const servedBefore = Buffer.from(await before.arrayBuffer());
    const statePath = `kobo/${pair.koboToken}/v1/library/${pair.entitlementId}/state`;
    const stateBefore = await (await fetch(`${base}/${statePath}`)).json();
    assert.equal(stateBefore[0].Statistics.MinutesRead, 81);
    const sourceFileBefore = await fetch(`${base}/books/files/${pair.sourceFileId}/serve`, { headers });
    assert.equal(sourceFileBefore.status, 200);
    const sourceBytes = Buffer.from(await sourceFileBefore.arrayBuffer());
    const targetPassage = (
      await post("annotations/native/operations", {
        deviceId: "E03 target primary preservation",
        operations: [
          {
            operationId: randomUUID(),
            clientId: randomUUID(),
            bookId: pair.targetBookId,
            baseVersion: 0,
            action: "create",
            payload: {
              kind: "text_note",
              cfi: "epubcfi(/6/2!/4/2:1)",
              text: "Retained target passage",
              note: "Target anchor survives a Kobo primary change",
            },
          },
        ],
      })
    ).results[0];
    assert.equal(targetPassage.status, "applied");
    const targetPassagesBefore = await (await fetch(`${base}/books/${pair.targetBookId}/annotations?page=1&pageSize=100`, { headers })).json();
    assert.equal(targetPassagesBefore.items.find((item) => item.id === targetPassage.annotation.id).jumpFileId, pair.targetFileId);
    const preview = await post("book-duplicates/merge/preview", { sourceBookId: pair.sourceBookId, targetBookId: pair.targetBookId });
    assert.equal(preview.canApply, true, preview.blockers.join("; "));
    const body = { sourceBookId: pair.sourceBookId, targetBookId: pair.targetBookId, previewToken: preview.previewToken };
    const targetSlot = join(pair.appDataPath, "covers", String(pair.targetBookId), "ebook");
    await mkdir(targetSlot, { recursive: true });
    await writeFile(join(targetSlot, ".fixture-pending-merge"), "Keep the target unchanged until retry");
    const interrupted = await fetch(`${base}/book-duplicates/merge/apply`, {
      method: "POST",
      headers: { ...headers, "Content-Type": "application/json" },
      body: JSON.stringify(body),
    });
    assert.equal(interrupted.status, 409, await interrupted.text());
    assert.equal(
      (await fetch(`${base}/books/${pair.sourceBookId}`, { headers })).status,
      404,
      "Database merge committed before cover promotion was blocked",
    );
    await rm(targetSlot, { recursive: true });
    assert.equal(
      (await post("book-duplicates/merge/apply", body)).alreadyApplied,
      true,
      "The pending receipt recovers without the deleted source book",
    );
    const target = await (await fetch(`${base}/books/${pair.targetBookId}`, { headers })).json();
    assert.equal(target.files.find((file) => file.role === "primary")?.id, pair.sourceFileId, "Kobo deliveries retain their original primary file");
    assert.deepEqual(
      target.files.map((file) => file.id).sort((a, b) => a - b),
      [pair.sourceFileId, pair.targetFileId].sort((a, b) => a - b),
    );
    const targetPassagesAfter = await (await fetch(`${base}/books/${pair.targetBookId}/annotations?page=1&pageSize=100`, { headers })).json();
    assert.equal(
      targetPassagesAfter.items.find((item) => item.id === targetPassage.annotation.id).jumpFileId,
      pair.targetFileId,
      "Legacy target passage anchors retain their original file when Kobo changes the keeper primary",
    );
    const sourceFileAfter = await fetch(`${base}/books/files/${pair.sourceFileId}/serve`, { headers });
    assert.equal(sourceFileAfter.status, 200);
    assert.deepEqual(Buffer.from(await sourceFileAfter.arrayBuffer()), sourceBytes);
    const after = await fetch(`${base}/books/${pair.targetBookId}/cover?medium=ebook`, { headers });
    assert.ok(after.ok);
    assert.deepEqual(Buffer.from(await after.arrayBuffer()), servedBefore);
    const archiveParent = join(pair.appDataPath, "covers", String(pair.targetBookId), "merged", String(pair.sourceBookId));
    const archives = (await readdir(archiveParent)).filter((name) => /^[a-f0-9]{64}$/.test(name));
    assert.equal(archives.length, 1);
    assert.deepEqual(await readFile(join(archiveParent, archives[0], "ebook", "cover_custom.jpg")), servedBefore);
    const stateAfter = await (await fetch(`${base}/${statePath}`)).json();
    assert.deepEqual(stateAfter, stateBefore);
    assert.equal((await post("book-duplicates/merge/apply", body)).alreadyApplied, true);
  } finally {
    await fetch(`${base}/auth/logout`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ refreshToken: session.refreshToken }),
    });
  }
});
