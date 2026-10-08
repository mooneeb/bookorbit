import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { test } from "node:test";

const base = process.env.IPAD_PDF_PAGE_API_URL ?? "http://localhost:16482/api/v1";

async function request(path, token, body) {
  return fetch(`${base}/${path}`, {
    method: body ? "POST" : "GET",
    headers: {
      ...(token ? { Authorization: `Bearer ${token}` } : {}),
      ...(body ? { "Content-Type": "application/json" } : {}),
    },
    ...(body ? { body: JSON.stringify(body) } : {}),
  });
}

async function json(response, expectedStatus = 200) {
  assert.equal(response.status, expectedStatus, await response.clone().text());
  return response.json();
}

async function login(username) {
  return (
    await json(
      await request("auth/login", null, {
        username,
        password: "IpadFixture123",
        clientKind: "native",
        deviceLabel: "Private PDF page fixture",
      }),
    )
  ).accessToken;
}

const rect = { x: 30, y: 40, width: 90, height: 18 };
const position = (page) => ({ page, rect, rects: [rect] });

test("IPAD-E02-A01-PDF-page-collection: bounded private page queries include native and legacy anchors without other accounts", async () => {
  const reader = await login("ipad-reader");
  const owner = await login("ipad-owner");
  const restricted = await login("ipad-restricted");
  const marker = `page-query-${randomUUID()}`;
  const route = (page, collectionPage = 1, size = 100) =>
    `books/1/annotations?bookFileId=1&pdfPage=${page}&page=${collectionPage}&pageSize=${size}&excludeSourceInk=true&search=${marker}`;
  await json(await request(route(0), reader));

  async function native(token, page, text) {
    const response = await json(
      await request("annotations/native/operations", token, {
        deviceId: "private-pdf-page-http",
        operations: [
          {
            operationId: randomUUID(),
            clientId: randomUUID(),
            bookId: 1,
            baseVersion: 0,
            action: "create",
            payload: { kind: "text_note", bookFileId: 1, pdf: position(page), text: `${marker} ${text}`, note: `${marker} note` },
          },
        ],
      }),
      201,
    );
    assert.equal(response.results[0].status, "applied");
    return response.results[0].annotation;
  }

  const nativeFirst = await native(reader, 0, "native first page");
  const nativeSecond = await native(reader, 1, "native second page");
  const foreign = await native(owner, 0, "other account");
  const legacy = await json(
    await request("books/1/annotations", reader, {
      bookFileId: 1,
      pdf: position(0),
      text: `${marker} legacy first page`,
      note: `${marker} legacy note`,
    }),
    201,
  );
  const passage = await json(
    await request("books/1/annotations", reader, {
      bookFileId: 1,
      cfi: "epubcfi(/6/2!/4/2:0)",
      text: `${marker} passage only`,
    }),
    201,
  );

  const first = await json(await request(route(0), reader));
  assert.equal(first.total, 2);
  assert.equal(first.page, 1);
  assert.equal(first.pageSize, 100);
  assert.deepEqual(
    first.items.map((item) => item.id).sort((a, b) => a - b),
    [nativeFirst.id, legacy.id].sort((a, b) => a - b),
  );
  assert.equal(
    first.items.every((item) => item.pdf.page === 0 && item.jumpFileId === 1 && item.kind !== "pdf_ink"),
    true,
  );
  assert.equal(first.stats.totalHighlights, 2);
  assert.equal(
    first.items.some((item) => item.id === foreign.id || item.id === passage.id),
    false,
  );

  const second = await json(await request(route(1), reader));
  assert.equal(second.total, 1);
  assert.deepEqual(
    second.items.map((item) => item.id),
    [nativeSecond.id],
  );
  const ownOwnerPage = await json(await request(route(0), owner));
  assert.equal(ownOwnerPage.total, 1);
  assert.deepEqual(
    ownOwnerPage.items.map((item) => item.id),
    [foreign.id],
  );
  const pageOne = await json(await request(route(0, 1, 1), reader));
  const pageTwo = await json(await request(route(0, 2, 1), reader));
  assert.equal(pageOne.total, 2);
  assert.equal(pageTwo.total, 2);
  assert.equal(pageOne.items.length, 1);
  assert.equal(pageTwo.items.length, 1);
  assert.notEqual(pageOne.items[0].id, pageTwo.items[0].id);
  assert.deepEqual((await json(await request(route(2), reader))).items, []);
  assert.equal((await request(route(0))).status, 401);
  assert.equal((await request(route(0), restricted)).status, 404);

  for (const invalid of ["", " ", "-1", "0.5", "invalid", "9007199254740992"]) {
    assert.equal((await request(route(invalid), reader)).status, 400, `invalid pdfPage=${invalid}`);
  }
  assert.equal((await request(`${route(0)}&unexpected=1`, reader)).status, 400);
  assert.equal((await request(route(0, 1, 101), reader)).status, 400);
  assert.equal((await request(`books/1/annotations?bookFileId=2&pdfPage=0&page=1`, reader)).status, 400);
});
