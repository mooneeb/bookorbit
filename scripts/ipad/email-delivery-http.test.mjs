import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { createHash, randomUUID } from "node:crypto";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { createRequire } from "node:module";
import { resolve } from "node:path";
import { test } from "node:test";
import { promisify } from "node:util";
import { startEmailReceiver } from "./e04-smtp-receiver.mjs";

const require = createRequire(new URL("../../server/package.json", import.meta.url));
const { PDFDocument, PDFDict, PDFName, PDFNumber } = require("pdf-lib");
const sharp = require("sharp");
const execute = promisify(execFile);
const base = process.env.IPAD_E04_API_URL ?? "http://localhost:16502/api/v1";
const artifacts = resolve("test-results/ipad", process.env.IPAD_TEST_RUN ?? "e04-email", "email");
async function request(path, token, body, method = body ? "POST" : "GET") {
  return fetch(`${base}/${path}`, {
    method,
    headers: { ...(token ? { Authorization: `Bearer ${token}` } : {}), ...(body ? { "Content-Type": "application/json" } : {}) },
    ...(body ? { body: JSON.stringify(body) } : {}),
    signal: AbortSignal.timeout(30_000),
  });
}
async function json(path, token, body, method) {
  const response = await request(path, token, body, method);
  assert.ok(response.ok, `${path}: ${response.status} ${await response.clone().text()}`);
  return response.json();
}
async function login(username) {
  return json("auth/login", null, { username, password: "IpadFixture123", clientKind: "native", deviceLabel: "E04 email artifact QA" });
}
async function eventually(action, predicate, timeout = 15_000) {
  const until = Date.now() + timeout;
  let result;
  while (Date.now() < until) {
    result = await action();
    if (predicate(result)) return result;
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  assert.fail(`Timed out waiting for email outcome: ${JSON.stringify(result)}`);
}
export function emailAttachments(raw) {
  const boundary = /boundary="([^"]+)"/i.exec(raw)?.[1];
  assert.ok(boundary, "received message is multipart MIME");
  return raw.split(`--${boundary}`).flatMap((part) => {
    if (!/Content-Disposition: attachment/i.test(part)) return [];
    const split = part.indexOf("\r\n\r\n");
    assert.ok(split >= 0);
    assert.match(part.slice(0, split), /Content-Transfer-Encoding: base64/i);
    return [{ filename: /filename="([^"]+)"/i.exec(part)?.[1], bytes: Buffer.from(part.slice(split + 4).replace(/\s/g, ""), "base64") }];
  });
}
async function source(token) {
  return json("annotations/native/files/1/source?bookId=1&page=0", token);
}
async function content(token) {
  const response = await request("books/files/1/serve", token);
  assert.equal(response.status, 200);
  return Buffer.from(await response.arrayBuffer());
}
function inkIDs(document) {
  return document.getPages().flatMap((page) =>
    (page.node.Annots()?.asArray() ?? []).flatMap((ref) => {
      const annotation = document.context.lookup(ref);
      if (!(annotation instanceof PDFDict)) return [];
      const id = annotation.lookupMaybe(PDFName.of("BookOrbitAnnotationId"), PDFNumber)?.asNumber();
      return id == null ? [] : [id];
    }),
  );
}
async function render(bytes, name) {
  await mkdir(artifacts, { recursive: true });
  const file = resolve(artifacts, `${name}.pdf`);
  await writeFile(file, bytes);
  await execute(process.env.IPAD_PDFTOPPM ?? "/opt/homebrew/bin/pdftoppm", [
    "-f",
    "1",
    "-singlefile",
    "-scale-to-x",
    "600",
    "-scale-to-y",
    "800",
    "-png",
    file,
    resolve(artifacts, name),
  ]);
  const image = await sharp(await readFile(resolve(artifacts, `${name}.png`)))
    .removeAlpha()
    .raw()
    .toBuffer({ resolveWithObject: true });
  const offset = (300 * image.info.width + 150) * image.info.channels;
  return { image, pixel: [...image.data.subarray(offset, offset + 3)] };
}

test("IPAD-E04-A03/A04-email: selected current PDF reaches SMTP receiver with visible source ink and committed deletion; owned jobs and retry remain truthful", async (t) => {
  const receiver = await startEmailReceiver();
  const owner = await login("ipad-owner");
  const reader = await login("ipad-reader");
  const restricted = await login("ipad-restricted");
  const token = owner.accessToken;
  const name = `E04 SMTP ${randomUUID()}`;
  const provider = await json("email/providers", token, {
    name,
    host: "127.0.0.1",
    port: receiver.smtpPort,
    fromAddress: "sender@bookorbit.test",
    auth: false,
    ssl: false,
    startTls: false,
    tlsRejectUnauthorized: true,
  });
  const recipient = await json("email/recipients", token, {
    name,
    email: `${randomUUID()}@kindle.test`,
    deviceType: "kindle",
    preferredFormat: "pdf",
  });
  let annotation;
  t.after(async () => {
    if (annotation && !annotation.deletedAt) {
      const current = await source(token);
      await json("annotations/native/operations", token, {
        deviceId: "e04-mail",
        operations: [
          {
            operationId: randomUUID(),
            clientId: annotation.clientId,
            annotationId: annotation.id,
            bookId: 1,
            baseVersion: annotation.version,
            action: "delete",
            payload: { sourceRevision: current.sourceRevision, pageFingerprint: current.pageFingerprint },
          },
        ],
      });
    }
    for (const [route, id] of [
      ["providers", provider.id],
      ["recipients", recipient.id],
    ])
      assert.equal((await request(`email/${route}/${id}`, token, null, "DELETE")).status, 204);
    for (const session of [owner, reader, restricted])
      assert.equal((await request("auth/logout", null, { refreshToken: session.refreshToken })).status, 200);
    await receiver.close();
  });
  assert.equal(provider.hasPassword, false);
  assert.equal("passwordEnc" in provider, false);
  assert.equal((await request("email/send", null, { bookIds: [1], fileId: 1, recipientIds: [recipient.id], providerId: provider.id })).status, 401);
  assert.equal((await request("email/providers", restricted.accessToken)).status, 403);
  assert.equal(
    (
      await request("email/providers", reader.accessToken, {
        name,
        host: "localhost",
        port: 25,
        auth: false,
        ssl: false,
        startTls: false,
        tlsRejectUnauthorized: true,
      })
    ).status,
    403,
  );
  assert.equal(
    (await request("email/send", reader.accessToken, { bookIds: [1], fileId: 1, recipientIds: [recipient.id], providerId: provider.id })).status,
    403,
  );
  assert.equal((await request("email/send", token, { bookIds: [2], fileId: 1, recipientIds: [recipient.id], providerId: provider.id })).status, 404);
  const checked = await json(`email/providers/${provider.id}/test`, token, null, "POST");
  assert.equal(checked.success, true);
  const before = await content(token);
  const baseline = await render(before, "email-before");
  const initial = await source(token);
  const create = await json("annotations/native/operations", token, {
    deviceId: "e04-mail",
    operations: [
      {
        operationId: randomUUID(),
        clientId: randomUUID(),
        bookId: 1,
        baseVersion: 0,
        action: "create",
        payload: {
          kind: "pdf_ink",
          bookFileId: 1,
          text: "",
          pdf: { page: 0, rect: { x: 76, y: 296, width: 108, height: 8 }, rects: [] },
          drawing: {
            format: "bookorbit-ink-v1",
            strokes: [
              {
                id: "e04-mail-red",
                color: "#ff0000",
                width: 8,
                points: [
                  { x: 80, y: 300 },
                  { x: 180, y: 300 },
                ],
              },
            ],
          },
          sourceRevision: initial.sourceRevision,
          pageFingerprint: initial.pageFingerprint,
        },
      },
    ],
  });
  assert.equal(create.results[0].status, "applied");
  assert.equal(create.results[0].publication.status, "published");
  annotation = create.results[0].annotation;
  async function sendAndReceive(expectedBytes, label) {
    const response = await request("email/send", token, { bookIds: [1], fileId: 1, recipientIds: [recipient.id], providerId: provider.id });
    assert.equal(response.status, 202);
    const accepted = await response.json();
    assert.equal(accepted.queued, 1);
    assert.equal(accepted.logIds.length, 1);
    const jobs = await eventually(
      () => json("email/log?bookId=1&page=0&size=20", token),
      (rows) => rows.some((row) => row.id === accepted.logIds[0] && row.status === "sent"),
    );
    const job = jobs.find((row) => row.id === accepted.logIds[0]);
    assert.equal(job.bookFileId, 1);
    assert.equal(job.toEmail, recipient.email);
    assert.ok(job.sentAt);
    assert.equal(job.errorMessage, null);
    const messages = await (await fetch(`${receiver.httpURL}/messages`)).json();
    const message = messages.at(-1);
    assert.match(message.raw, /Subject: Convert\r\n/i);
    assert.ok(message.recipients.includes(`<${recipient.email}>`));
    const attachments = emailAttachments(message.raw);
    assert.equal(attachments.length, 1);
    assert.deepEqual(attachments[0].bytes, expectedBytes, "SMTP attachment contains the exact current served source bytes");
    await writeFile(resolve(artifacts, `${label}.eml`), message.raw);
    assert.equal((await request(`email/log/${job.id}/resend`, reader.accessToken, null, "POST")).status, 403);
    return attachments[0].bytes;
  }
  const marked = await content(token);
  assert.notEqual(createHash("sha256").update(marked).digest("hex"), createHash("sha256").update(before).digest("hex"));
  const received = await sendAndReceive(marked, "email-source-ink");
  assert.ok(inkIDs(await PDFDocument.load(received)).includes(annotation.id));
  const rendered = await render(received, "email-source-ink");
  assert.ok(rendered.pixel[0] > 240 && rendered.pixel[1] < 40 && rendered.pixel[2] < 40, "ordinary PDF renderer sees source red ink");
  const updated = await source(token);
  const removed = await json("annotations/native/operations", token, {
    deviceId: "e04-mail",
    operations: [
      {
        operationId: randomUUID(),
        clientId: annotation.clientId,
        annotationId: annotation.id,
        bookId: 1,
        baseVersion: annotation.version,
        action: "delete",
        payload: { sourceRevision: updated.sourceRevision, pageFingerprint: updated.pageFingerprint },
      },
    ],
  });
  assert.equal(removed.results[0].publication.status, "published");
  annotation = removed.results[0].annotation;
  const deleted = await content(token);
  const redelivered = await sendAndReceive(deleted, "email-source-deleted");
  assert.ok(!inkIDs(await PDFDocument.load(redelivered)).includes(annotation.id));
  assert.deepEqual(
    (await render(redelivered, "email-source-deleted")).pixel,
    baseline.pixel,
    "committed deletion is visible in the independently rendered new attachment",
  );
  await fetch(`${receiver.httpURL}/mode`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ mode: "reject" }),
  });
  const rejected = await json("email/send", token, { bookIds: [1], fileId: 1, recipientIds: [recipient.id], providerId: provider.id });
  const pending = (
    await eventually(
      () => json("email/log?bookId=1&page=0&size=20", token),
      (rows) => rows.some((row) => row.id === rejected.logIds[0] && row.attemptCount === 1),
    )
  ).find((row) => row.id === rejected.logIds[0]);
  assert.equal(pending.status, "pending");
  assert.ok(pending.nextRetryAt);
  assert.match(pending.errorMessage, /controlled delivery rejection/);
  await fetch(`${receiver.httpURL}/mode`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ mode: "accept" }),
  });
  const recovered = (
    await eventually(
      () => json("email/log?bookId=1&page=0&size=20", token),
      (rows) => rows.some((row) => row.id === pending.id && row.status === "sent"),
      40_000,
    )
  ).find((row) => row.id === pending.id);
  assert.equal(recovered.attemptCount, 1);
  assert.equal(recovered.errorMessage, null);
  const messages = await (await fetch(`${receiver.httpURL}/messages`)).json();
  assert.equal(messages.length, 3, "rejected SMTP attempt did not produce a duplicate accepted message");
  assert.deepEqual(emailAttachments(messages.at(-1).raw)[0].bytes, deleted);
});
