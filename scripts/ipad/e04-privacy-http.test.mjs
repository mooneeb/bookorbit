import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { test } from "node:test";

const base = process.env.IPAD_API_BASE ?? "http://localhost:16502/api/v1";
if (!/^http:\/\/(localhost|127\.0\.0\.1):\d+\/api\/v1$/.test(base)) {
  throw new Error("Privacy HTTP tests require an isolated localhost BookOrbit server");
}
const permittedBookID = Number(process.env.IPAD_E04_PRIVACY_PERMITTED_BOOK_ID ?? 1);
const excludedBookID = Number(process.env.IPAD_E04_PRIVACY_EXCLUDED_BOOK_ID ?? 2);
const password = "IpadFixture123";

async function request(path, { token, method = "GET", body, viewSessionID } = {}) {
  return fetch(`${base}/${path}`, {
    method,
    headers: {
      ...(token ? { Authorization: `Bearer ${token}` } : {}),
      ...(body ? { "Content-Type": "application/json" } : {}),
      ...(viewSessionID ? { "x-reading-insights-view-session": viewSessionID } : {}),
    },
    ...(body ? { body: JSON.stringify(body) } : {}),
  });
}

async function json(path, options) {
  const response = await request(path, options);
  assert.ok(response.ok, `${path}: ${response.status} ${await response.clone().text()}`);
  return response.json();
}

async function login(username) {
  return json("auth/login", {
    method: "POST",
    body: { username, password, clientKind: "native", deviceLabel: "E04 privacy HTTP" },
  });
}

async function createReader(ownerToken, suffix, permissionNames, libraryIds) {
  const username = `e04-privacy-${suffix}-${randomUUID().slice(0, 8)}`;
  const user = await json("users", {
    token: ownerToken,
    method: "POST",
    body: { username, name: username, email: `${username}@example.test`, permissionNames, libraryIds },
  });
  const reset = await request("auth/reset-password", {
    method: "POST",
    body: { token: new URL(user.resetUrl).searchParams.get("token"), newPassword: password },
  });
  assert.equal(reset.status, 204);
  return { user, session: await login(username) };
}

test("IPAD-E04-A02-HTTP: shared insights exclude restricted books, private annotations and source artifacts, and revoke existing sessions", async () => {
  const owner = await login("ipad-owner");
  const readers = [];
  try {
    const permitted = await json(`books/${permittedBookID}`, { token: owner.accessToken });
    const excluded = await json(`books/${excludedBookID}`, { token: owner.accessToken });
    const tags = await json("metadata/tags?q=E04%20restricted%20insight", { token: owner.accessToken });
    const restrictedTag = tags.find((tag) => tag.name === "E04 restricted insight");
    assert.ok(restrictedTag, "The isolated E04 fixture must seed the excluded book tag");
    const libraries = [...new Set([permitted.libraryId, excluded.libraryId])];
    const subject = await createReader(owner.accessToken, "subject", ["annotation_manage_own", "library_download"], libraries);
    readers.push(subject);
    const viewer = await createReader(owner.accessToken, "viewer", ["view_user_activity", "library_download"], [permitted.libraryId]);
    readers.push(viewer);
    const foreign = await createReader(owner.accessToken, "foreign", ["view_user_activity"], []);
    readers.push(foreign);
    const subjectToken = subject.session.accessToken;
    const viewerToken = viewer.session.accessToken;
    const filtersPath = `users/${viewer.user.id}/content-filters`;
    const filters = { includeTagIds: [], excludeTagIds: [restrictedTag.id], includeGenreIds: [], excludeGenreIds: [], seeOwnRequestedBooks: false };
    assert.equal((await request(filtersPath, { token: owner.accessToken, method: "PUT", body: filters })).status, 204);
    const file = permitted.files.find((item) => item.format === "pdf") ?? permitted.files[0];
    assert.ok(file);
    const sourcePath = `books/files/${file.id}/serve`;
    const sourceBefore = await request(sourcePath, { token: subjectToken });
    assert.equal(sourceBefore.status, 200);
    const originalBytes = Buffer.from(await sourceBefore.arrayBuffer());
    const privatePersonalNote = `PRIVATE PERSONAL ${randomUUID()}`;
    const privateHighlight = `PRIVATE HIGHLIGHT ${randomUUID()}`;
    await json(`books/${permittedBookID}/personal-note`, { token: subjectToken, method: "PATCH", body: { note: privatePersonalNote } });
    const annotation = await json(`books/${permittedBookID}/annotations`, {
      token: subjectToken,
      method: "POST",
      body: {
        text: privateHighlight,
        note: "Private passage note",
        color: "yellow",
        style: "highlight",
        ...(file.format === "pdf"
          ? {
              bookFileId: file.id,
              pdf: { page: 0, rect: { x: 0.1, y: 0.1, width: 0.2, height: 0.1 }, rects: [{ x: 0.1, y: 0.1, width: 0.2, height: 0.1 }] },
            }
          : { cfi: "epubcfi(/6/2!/4/2:0)" }),
      },
    });
    for (const [bookID, durationMinutes] of [
      [permittedBookID, 10],
      [excludedBookID, 20],
    ]) {
      await json(`books/${bookID}/sessions`, {
        token: subjectToken,
        method: "POST",
        body: {
          clientId: randomUUID(),
          startedAt: new Date(Date.now() - 7_200_000).toISOString(),
          durationMinutes,
        },
      });
    }
    const subjectID = subject.user.id;
    const summaryPath = `shared-reading-insights/${subjectID}/summary?days=30`;
    const detailPath = `shared-reading-insights/${subjectID}/detailed?days=30`;
    assert.equal((await request(`shared-reading-insights/${subjectID}/view-sessions`, { token: viewerToken, method: "POST" })).status, 403);
    await json("reading-insights-sharing/me", { token: subjectToken, method: "PATCH", body: { sharingLevel: "detailed" } });
    const view = await json(`shared-reading-insights/${subjectID}/view-sessions`, { token: viewerToken, method: "POST" });
    const viewing = { token: viewerToken, viewSessionID: view.viewSessionId };
    const summary = await json(summaryPath, viewing);
    assert.equal(summary.readingSeconds, 600);
    assert.equal(summary.sessionsCount, 1);
    assert.equal(
      summary.sourceCoverage.reduce((total, item) => total + item.readingSeconds, 0),
      600,
    );
    const detail = await json(detailPath, viewing);
    assert.deepEqual(
      detail.topBooks.map((book) => book.bookId),
      [permittedBookID],
    );
    assert.deepEqual(
      detail.recentBooks.map((book) => book.bookId),
      [permittedBookID],
    );
    const serialized = JSON.stringify({ summary, detail });
    for (const marker of [privatePersonalNote, privateHighlight, "Private passage note"]) assert.ok(!serialized.includes(marker));
    for (const forbiddenField of ["personalNote", "annotations", "drawing", "files", "absolutePath", "bookFileId"])
      assert.ok(!serialized.includes(`"${forbiddenField}"`));
    const viewerBook = await json(`books/${permittedBookID}`, { token: viewerToken });
    assert.notEqual(viewerBook.personalNote, privatePersonalNote);
    const viewerAnnotations = await json(`books/${permittedBookID}/annotations?page=1&pageSize=20`, { token: viewerToken });
    assert.ok(!viewerAnnotations.items.some((item) => item.id === annotation.id || item.text === privateHighlight));
    const sourceAfter = await request(sourcePath, { token: viewerToken });
    assert.equal(sourceAfter.status, 200);
    assert.deepEqual(Buffer.from(await sourceAfter.arrayBuffer()), originalBytes, "Private overlays must not alter delivered source bytes");
    const excludedFile = excluded.files[0];
    assert.ok(excludedFile);
    assert.equal((await request(`books/files/${excludedFile.id}/serve`, { token: viewerToken })).status, 404);
    assert.equal(
      (
        await request(`books/${excludedBookID}/sessions`, {
          token: viewerToken,
          method: "POST",
          body: { startedAt: new Date().toISOString(), durationMinutes: 1 },
        })
      ).status,
      404,
    );
    assert.equal((await request(filtersPath, { token: viewerToken, method: "PUT", body: filters })).status, 403);
    assert.equal((await request(summaryPath, { token: viewerToken })).status, 400);
    assert.equal((await request(summaryPath, { token: foreign.session.accessToken, viewSessionID: view.viewSessionId })).status, 403);
    await json("reading-insights-sharing/me", { token: subjectToken, method: "PATCH", body: { sharingLevel: "summary" } });
    assert.equal((await request(detailPath, viewing)).status, 403);
    const downgraded = await json(summaryPath, viewing);
    assert.equal(downgraded.sharingLevel, "summary");
    assert.ok(!JSON.stringify(downgraded).includes(permitted.title));
    const history = await json("reading-insights-sharing/me/access-history?page=1&pageSize=20", { token: subjectToken });
    assert.ok(history.items.some((item) => item.viewerUsername === viewer.user.username));
    await json("reading-insights-sharing/me", { token: subjectToken, method: "PATCH", body: { sharingLevel: "private" } });
    assert.equal((await request(summaryPath, viewing)).status, 403);
    assert.equal((await request(detailPath, viewing)).status, 403);
    assert.equal((await request(`shared-reading-insights/${subjectID}/view-sessions`, { token: viewerToken, method: "POST" })).status, 403);
    assert.deepEqual(await json("reading-insights-sharing/me/preview?days=30", { token: subjectToken }), {
      sharingLevel: "private",
      consentedAt: null,
    });
    await json("reading-insights-sharing/me", { token: subjectToken, method: "PATCH", body: { sharingLevel: "detailed" } });
    assert.equal(
      (await request(`users/${viewer.user.id}/libraries`, { token: owner.accessToken, method: "PUT", body: { libraryIds: [] } })).status,
      204,
    );
    assert.equal((await request(summaryPath, viewing)).status, 403, "Re-enabling consent must not restore a revoked view session");
    const newView = await json(`shared-reading-insights/${subjectID}/view-sessions`, { token: viewerToken, method: "POST" });
    const renewed = { token: viewerToken, viewSessionID: newView.viewSessionId };
    const afterRevocation = await json(summaryPath, renewed);
    assert.equal(afterRevocation.readingSeconds, 0);
    assert.equal(afterRevocation.sessionsCount, 0);
    const emptyDetail = await json(detailPath, renewed);
    assert.equal(emptyDetail.topBooks.length, 0);
    assert.equal(emptyDetail.topAuthors.length, 0);
    assert.equal((await request(sourcePath, { token: viewerToken })).status, 403);
    assert.equal(
      (
        await request("reading-insights-sharing/me", {
          token: subjectToken,
          method: "PATCH",
          body: { sharingLevel: "public", subjectUserId: viewer.user.id },
        })
      ).status,
      400,
    );
  } finally {
    for (const reader of readers.reverse()) {
      await request(`users/${reader.user.id}`, { token: owner.accessToken, method: "DELETE" });
    }
    await request("auth/logout", { method: "POST", body: { refreshToken: owner.refreshToken } });
  }
});
