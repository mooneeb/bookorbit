import { test } from "node:test";
import assert from "node:assert/strict";
import { createHash, randomBytes } from "node:crypto";
import { createRequire } from "node:module";

const require = createRequire(new URL("../../server/package.json", import.meta.url));
const { PDFDocument } = require("pdf-lib");
const sharp = require("sharp");

const base = "http://localhost:16482/api/v1";
async function request(path, { token, body, method = body ? "POST" : "GET" } = {}) {
  return fetch(`${base}/${path}`, {
    method,
    headers: { ...(token ? { Authorization: `Bearer ${token}` } : {}), ...(body ? { "Content-Type": "application/json" } : {}) },
    body: body ? JSON.stringify(body) : undefined,
  });
}
async function login(username) {
  const response = await request("auth/login", {
    body: { username, password: "IpadFixture123", clientKind: "native", deviceLabel: "iPad HTTP fixture" },
  });
  assert.equal(response.status, 200);
  assert.equal(response.headers.get("set-cookie"), null);
  return response.json();
}

test("IPAD-E01-A02/A05: cover writes enforce permissions and independent medium locks without changing denied artifacts", async () => {
  const editor = await login("ipad-editor");
  const reader = await login("ipad-reader");
  const restricted = await login("ipad-restricted");
  const selected = await sharp({ create: { width: 640, height: 960, channels: 3, background: { r: 48, g: 112, b: 192 } } })
    .png()
    .toBuffer();
  async function upload(medium, token, bytes = selected, type = "image/png") {
    const form = new FormData();
    form.set("file", new Blob([bytes], { type }), "selected.png");
    return fetch(`${base}/books/6/cover?medium=${medium}`, {
      method: "POST",
      headers: token ? { Authorization: `Bearer ${token}` } : {},
      body: form,
    });
  }
  async function record() {
    const response = await request("books/6", { token: editor.accessToken });
    assert.equal(response.status, 200);
    return response.json();
  }
  async function image(medium) {
    const response = await request(`books/6/cover?medium=${medium}&strict=true`, { token: editor.accessToken });
    assert.equal(response.status, 200);
    return Buffer.from(await response.arrayBuffer());
  }
  async function locks(lockedFields) {
    const response = await request("books/6/metadata-and-locks", {
      token: editor.accessToken,
      method: "PATCH",
      body: { metadata: {}, lockedFields },
    });
    assert.equal(response.status, 200);
  }
  const original = await record();
  const ebook = await image("ebook");
  const audio = await image("audio");
  try {
    for (const medium of ["ebook", "audio"]) {
      assert.equal((await upload(medium, reader.accessToken)).status, 403);
      assert.equal((await request(`books/6/cover?medium=${medium}`, { method: "DELETE", token: reader.accessToken })).status, 403);
      assert.equal((await upload(medium, restricted.accessToken)).status, 403);
    }
    assert.equal((await upload("ebook")).status, 401);
    assert.equal((await upload("unknown", editor.accessToken)).status, 400);
    assert.equal((await upload("ebook", editor.accessToken, Buffer.from("not an image"), "text/plain")).status, 400);
    assert.deepEqual((await record()).covers, original.covers);
    assert.deepEqual(await image("ebook"), ebook);
    assert.deepEqual(await image("audio"), audio);
    await locks(["cover", "audioCover"]);
    for (const medium of ["ebook", "audio"]) {
      assert.equal((await upload(medium, editor.accessToken)).status, 409);
      assert.equal((await request(`books/6/cover?medium=${medium}`, { method: "DELETE", token: editor.accessToken })).status, 409);
    }
    assert.deepEqual((await record()).covers, original.covers);
    assert.deepEqual(await image("ebook"), ebook);
    assert.deepEqual(await image("audio"), audio);
    await locks(["audioCover"]);
    assert.equal((await upload("ebook", editor.accessToken)).status, 204);
    const saved = await record();
    assert.equal(saved.covers.ebook.source, "custom");
    assert.deepEqual([saved.covers.ebook.width, saved.covers.ebook.height], [640, 960]);
    assert.notEqual(saved.coverVersion, original.coverVersion);
    assert.deepEqual(saved.covers.audio, original.covers.audio);
    assert.deepEqual(await image("audio"), audio);
    assert.equal((await upload("audio", editor.accessToken)).status, 409);
    const delivered = await image("ebook");
    const { data, info } = await sharp(delivered).removeAlpha().raw().toBuffer({ resolveWithObject: true });
    assert.deepEqual([info.width, info.height, info.channels], [640, 960, 3]);
    const offset = (10 * info.width + 10) * 3;
    for (const [channel, expected] of [48, 112, 192].entries()) assert.ok(Math.abs(data[offset + channel] - expected) <= 10);
    const reverted = await request("books/6/cover?medium=ebook", { method: "DELETE", token: editor.accessToken });
    assert.equal(reverted.status, 200);
    assert.deepEqual(await reverted.json(), { coverSource: "extracted" });
    assert.deepEqual(await image("ebook"), ebook);
    assert.deepEqual(await image("audio"), audio);
  } finally {
    await locks(original.lockedFields);
    for (const session of [editor, reader, restricted]) {
      assert.equal((await request("auth/logout", { body: { refreshToken: session.refreshToken } })).status, 200);
    }
  }
});

test("IPAD-E01-A02/A05: metadata updates distinguish omitted and cleared fields and enforce editing permission", async () => {
  const owner = await login("ipad-owner");
  const reader = await login("ipad-reader");
  const editor = await login("ipad-editor");
  assert.equal(editor.user.isSuperuser, false);
  assert.ok(editor.user.permissions.includes("library_edit_metadata"));
  const originalResponse = await request("books/1", { token: owner.accessToken });
  assert.equal(originalResponse.status, 200);
  const original = await originalResponse.json();
  const readerRecord = await request("books/1", { token: reader.accessToken });
  assert.equal(readerRecord.status, 200);
  try {
    assert.equal((await request("books/1/metadata", { token: reader.accessToken, method: "PATCH", body: { title: "Denied edit" } })).status, 403);
    const changed = await request("books/1/metadata", {
      token: editor.accessToken,
      method: "PATCH",
      body: { title: "HTTP corrected", subtitle: "Keep this subtitle", description: "Clear this description" },
    });
    assert.equal(changed.status, 200);
    assert.equal((await changed.json()).title, "HTTP corrected");
    const clear = await request("books/1/metadata", { token: editor.accessToken, method: "PATCH", body: { description: null } });
    assert.equal(clear.status, 200);
    const saved = await clear.json();
    assert.equal(saved.title, "HTTP corrected");
    assert.equal(saved.subtitle, "Keep this subtitle");
    assert.equal(saved.description, null);
    const reopened = await request("books/1", { token: reader.accessToken });
    assert.equal(reopened.status, 200);
    assert.equal((await reopened.json()).description, null);
    assert.equal((await request("books/1/metadata", { token: editor.accessToken, method: "PATCH", body: { title: "x".repeat(1001) } })).status, 400);
    assert.equal(
      (await request("books/1/metadata", { token: editor.accessToken, method: "PATCH", body: { title: "e\u0301".repeat(501) } })).status,
      400,
    );
    for (const field of ["title", "subtitle"]) {
      const rejected = await request("books/1/metadata", {
        token: editor.accessToken,
        method: "PATCH",
        body: { [field]: "☕\uFE0F".repeat(750) },
      });
      assert.equal(rejected.status, 400);
    }
    const unicodeTitle = "😀".repeat(750);
    const accepted = await request("books/1/metadata", { token: editor.accessToken, method: "PATCH", body: { title: unicodeTitle } });
    assert.equal(accepted.status, 200);
    assert.equal((await accepted.json()).title, unicodeTitle);
    assert.equal(
      (await request("books/1/metadata", { token: editor.accessToken, method: "PATCH", body: { coverUrl: "https://invalid.example/cover" } })).status,
      400,
    );
    assert.equal((await request("books/1/metadata", { method: "PATCH", body: { title: "Anonymous edit" } })).status, 401);
  } finally {
    const restored = await request("books/1/metadata", {
      token: owner.accessToken,
      method: "PATCH",
      body: { title: original.title, subtitle: original.subtitle, description: original.description },
    });
    assert.equal(restored.status, 200);
  }
});

test("IPAD-E01-A02: relation names preserve Unicode and reject excessive names without changing the record", async () => {
  const editor = await login("ipad-editor");
  const originalResponse = await request("books/4", { token: editor.accessToken });
  assert.equal(originalResponse.status, 200);
  const original = await originalResponse.json();
  const expected = { authors: ["😀".repeat(300)], genres: ["😀".repeat(150)], tags: ["☕\uFE0F".repeat(100)] };
  async function names() {
    const response = await request("books/4", { token: editor.accessToken });
    assert.equal(response.status, 200);
    const book = await response.json();
    return { authors: book.authors.map((author) => author.name), genres: book.genres, tags: book.tags };
  }
  try {
    const accepted = await request("books/4/metadata", { token: editor.accessToken, method: "PATCH", body: expected });
    assert.equal(accepted.status, 200);
    assert.deepEqual(await names(), expected);
    for (const [field, value] of [
      ["authors", "e\u0301".repeat(251)],
      ["genres", "😀".repeat(201)],
      ["tags", "☕\uFE0F".repeat(101)],
    ]) {
      for (const route of ["metadata", "metadata-and-locks"]) {
        const metadata = { [field]: [value] };
        const rejected = await request(`books/4/${route}`, {
          token: editor.accessToken,
          method: "PATCH",
          body: route === "metadata" ? metadata : { metadata, lockedFields: [] },
        });
        assert.equal(rejected.status, 400, `${route}: excessive ${field}`);
        assert.deepEqual(await names(), expected);
      }
    }
  } finally {
    const restored = await request("books/4/metadata", {
      token: editor.accessToken,
      method: "PATCH",
      body: { authors: original.authors.map((author) => author.name), genres: original.genres, tags: original.tags },
    });
    assert.equal(restored.status, 200);
  }
});

test("IPAD-E01-A02/A05: collection pages bound results and preserve ownership and visible counts", async () => {
  const owner = await login("ipad-owner");
  const restricted = await login("ipad-restricted");
  const created = [];
  async function create(token, name, isPublic = false) {
    const response = await request("collections", { token, body: { name, icon: "folder", isPublic } });
    assert.equal(response.status, 201);
    const collection = await response.json();
    created.push({ id: collection.id, token });
    return collection;
  }
  async function page(token, query) {
    const response = await request(`collections/page?${new URLSearchParams(query)}`, { token });
    assert.equal(response.status, 200);
    return response.json();
  }
  try {
    for (let index = 0; index < 55; index++) await create(owner.accessToken, `Paged collection ${String(index).padStart(3, "0")}`);
    await create(restricted.accessToken, "Paged private reader collection");
    await create(restricted.accessToken, "Paged public reader collection", true);
    const first = await page(owner.accessToken, { q: "Paged", size: "40", page: "0", mediaType: "books", owned: "false" });
    assert.equal(first.total, 56);
    assert.equal(first.items.length, 40);
    assert.equal(first.page, 0);
    assert.equal(first.size, 40);
    assert.ok(first.items.every((item) => item.isOwner));
    const next = await page(owner.accessToken, { q: "Paged", size: "40", page: "1", owned: "true" });
    assert.equal(next.total, 55);
    assert.equal(next.items.length, 15);
    assert.equal(next.items[0].name, "Paged collection 040");
    assert.ok(next.items.every((item) => item.isOwner));
    const readerPage = await page(restricted.accessToken, { q: "Paged", size: "40", page: "0" });
    assert.equal(readerPage.total, 2);
    assert.ok(readerPage.items.every((item) => item.userId === restricted.user.id));
    const shared = await create(owner.accessToken, "Résumé %_ shelf", true);
    const add = await request(`collections/${shared.id}/books`, { token: owner.accessToken, body: { bookIds: [1] } });
    assert.equal(add.status, 201);
    assert.equal((await add.json()).bookCount, 1);
    const ownedSearch = await page(owner.accessToken, { q: "resume %_", owned: "true" });
    assert.deepEqual(
      ownedSearch.items.map((item) => item.id),
      [shared.id],
    );
    const visibleSearch = await page(restricted.accessToken, { q: "resume %_" });
    assert.equal(visibleSearch.total, 1);
    assert.equal(visibleSearch.items[0].bookCount, 0);
    assert.equal(visibleSearch.items[0].isOwner, false);
    const hiddenBooks = await request(`collections/${shared.id}/books/query`, {
      token: restricted.accessToken,
      body: { sort: [], pagination: { page: 0, size: 40 } },
    });
    assert.equal(hiddenBooks.status, 201);
    assert.equal((await hiddenBooks.json()).total, 0);
    assert.equal(
      (await request(`collections/${shared.id}`, { token: restricted.accessToken, method: "PATCH", body: { name: "Taken over" } })).status,
      403,
    );
    assert.equal((await request(`collections/${shared.id}/books`, { token: restricted.accessToken, body: { bookIds: [1] } })).status, 403);
    assert.equal((await request(`collections/${created[0].id}`, { token: restricted.accessToken })).status, 403);
    assert.equal((await page(restricted.accessToken, { q: "resume %_", owned: "true" })).total, 0);
    for (const query of [
      "size=101",
      "size=1.5",
      "page=-1",
      "page=2000&size=40",
      "owned=maybe",
      "mediaType=invalid",
      "unexpected=true",
      `q=${"x".repeat(256)}`,
    ]) {
      assert.equal((await request(`collections/page?${query}`, { token: owner.accessToken })).status, 400, query);
    }
    assert.equal((await request("collections/page")).status, 401);
  } finally {
    for (const collection of created.reverse()) {
      assert.equal((await request(`collections/${collection.id}`, { token: collection.token, method: "DELETE" })).status, 204);
    }
  }
});

test("IPAD-E01-A01: native credentials rotate and query a bounded 50,000-book library", async () => {
  const session = await login("ipad-owner");
  assert.equal(session.user.isSuperuser, true);
  assert.equal(typeof session.sessionId, "number");
  const query = { sort: [{ field: "title", dir: "asc" }], pagination: { page: 0, size: 40 } };
  const response = await request("books/query", { token: session.accessToken, body: query });
  assert.equal(response.status, 201);
  const page = await response.json();
  assert.equal(page.total, 50_000);
  assert.equal(page.items.length, 40);
  assert.equal(page.size, 40);
  assert.equal(page.page, 0);
  assert.ok(JSON.stringify(page).length < 100_000);
  const search = await request("books/query", { token: session.accessToken, body: { ...query, q: "Orbit fixture" } });
  assert.equal(search.status, 201);
  assert.deepEqual(
    (await search.json()).items.map((book) => book.title),
    ["Orbit fixture"],
  );
  const detail = await (await request("books/1", { token: session.accessToken })).json();
  assert.equal(detail.files.length, 1);
  assert.equal(detail.files[0].format, "pdf");
  const delivery = await request(`books/files/${detail.files[0].id}/serve`, { token: session.accessToken });
  assert.equal(delivery.status, 200);
  assert.match(delivery.headers.get("content-type"), /^application\/pdf/);
  const bytes = new Uint8Array(await delivery.arrayBuffer());
  assert.equal(bytes.length, detail.files[0].sizeBytes);
  assert.equal((await PDFDocument.load(bytes)).getPageCount(), 3);
  const range = await fetch(`${base}/books/files/${detail.files[0].id}/serve`, {
    headers: { Authorization: `Bearer ${session.accessToken}`, Range: "bytes=0-31" },
  });
  assert.equal(range.status, 206);
  assert.equal(range.headers.get("content-range"), `bytes 0-31/${bytes.length}`);
  assert.deepEqual(new Uint8Array(await range.arrayBuffer()), bytes.slice(0, 32));
  const rotated = await request("auth/refresh", { body: { refreshToken: session.refreshToken } });
  assert.equal(rotated.status, 200);
  const next = await rotated.json();
  assert.equal(next.sessionId, session.sessionId);
  assert.notEqual(next.refreshToken, session.refreshToken);
  assert.equal((await request("auth/me", { token: next.accessToken })).status, 200);
  assert.equal((await request("auth/logout", { body: { refreshToken: next.refreshToken } })).status, 200);
  assert.equal((await request("auth/me", { token: next.accessToken })).status, 401);
});

test("IPAD-E01-A05: restricted readers cannot browse or download another library", async () => {
  const session = await login("ipad-restricted");
  assert.deepEqual(await (await request("libraries", { token: session.accessToken })).json(), []);
  const response = await request("books/query", { token: session.accessToken, body: { sort: [], pagination: { page: 0, size: 40 } } });
  assert.equal(response.status, 201);
  assert.equal((await response.json()).total, 0);
  assert.equal((await request("books/1", { token: session.accessToken })).status, 404);
  assert.equal((await request("books/files/1/serve", { token: session.accessToken })).status, 403);
});

test("IPAD-E01-A01: the private and existing native OIDC callbacks coexist", async () => {
  for (const redirectUri of ["bookorbit-private://oauth2-callback", "bookorbit://oauth2-callback"]) {
    const start = await request("auth/oidc/ipad-fixture/state", { body: {} });
    assert.equal(start.status, 200);
    const { state, authorizationEndpoint } = await start.json();
    const codeVerifier = randomBytes(32).toString("base64url");
    const nonce = randomBytes(32).toString("base64url");
    const url = new URL(authorizationEndpoint);
    url.search = new URLSearchParams({
      redirect_uri: redirectUri,
      state,
      nonce,
      client_id: "ipad-test-client",
      code_challenge: createHash("sha256").update(codeVerifier).digest("base64url"),
      code_challenge_method: "S256",
      response_type: "code",
      scope: "openid profile",
    }).toString();
    const authorization = await fetch(url, { redirect: "manual" });
    assert.equal(authorization.status, 302);
    const code = new URL(authorization.headers.get("location")).searchParams.get("code");
    const response = await request("auth/oidc/callback", { body: { code, codeVerifier, redirectUri, nonce, state, clientKind: "native" } });
    assert.equal(response.status, 200);
    const session = await response.json();
    assert.equal(session.user.username, "ipad-owner");
    assert.equal(typeof session.refreshToken, "string");
    assert.equal(response.headers.get("set-cookie"), null);
    assert.equal((await request("auth/me", { token: session.accessToken })).status, 200);
  }
});

test("IPAD-E01-A01: native OIDC callbacks require an exact allowlisted URI", async () => {
  for (const redirectUri of ["bookorbit-private://oauth2-callback?next=evil", "evil://oauth2-callback"]) {
    const start = await request("auth/oidc/ipad-fixture/state", { body: {} });
    const { state } = await start.json();
    const response = await request("auth/oidc/callback", {
      body: {
        code: "fixture-code",
        codeVerifier: "fixture-verifier",
        redirectUri,
        nonce: "fixture-nonce",
        state,
        clientKind: "native",
      },
    });
    assert.equal(response.status, 400);
  }
});
