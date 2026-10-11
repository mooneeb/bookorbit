import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { createRequire } from "node:module";
import { mkdir, writeFile } from "node:fs/promises";
import { test } from "node:test";

const require = createRequire(new URL("../../server/package.json", import.meta.url));
const unzipper = require("unzipper");
const base = "http://localhost:16482/api/v1";
const selected = [1, 2];
const unselected = 3;
const digest = (bytes) => createHash("sha256").update(bytes).digest("hex");
async function request(path, token, body, method = body ? "POST" : "GET") {
  return fetch(`${base}/${path}`, {
    method,
    headers: { ...(token ? { Authorization: `Bearer ${token}` } : {}), ...(body ? { "Content-Type": "application/json" } : {}) },
    body: body ? JSON.stringify(body) : undefined,
  });
}
async function login(name) {
  const response = await request("auth/login", null, {
    username: name,
    password: "IpadFixture123",
    clientKind: "native",
    deviceLabel: "Bulk acceptance",
  });
  assert.equal(response.status, 200);
  return response.json();
}
async function record(id, token) {
  const response = await request(`books/${id}`, token);
  assert.equal(response.status, 200);
  return response.json();
}
async function preview(token, fields) {
  const response = await request("books/bulk-edit-metadata/preview", token, { bookIds: selected, fields });
  assert.equal(response.status, 201, await response.clone().text());
  return response.json();
}
const versions = (preview) => preview.books.map(({ bookId, updatedAt }) => ({ bookId, updatedAt }));

test("IPAD-E03-A04-HTTP: selected previews, stale/repeated apply, custom fields, denied access and real exported bytes", async () => {
  const [editor, reader, restricted, owner] = await Promise.all(["ipad-editor", "ipad-reader", "ipad-restricted", "ipad-owner"].map(login));
  const token = editor.accessToken;
  const originals = await Promise.all([...selected, unselected].map((id) => record(id, token)));
  const fields = { publisher: { value: "E03 Selected Press" }, tags: { mode: "add", values: ["E03 selected batch"] } };
  let custom;
  let annotation;
  let originalOwnerProgress;
  try {
    const originalProgress = await request("books/files/2/progress", owner.accessToken);
    assert.equal(originalProgress.status, 200);
    originalOwnerProgress = await originalProgress.json();
    assert.equal((await request("books/files/2/progress", owner.accessToken, { cfi: "epubcfi(/6/2!/4/2:0)", percentage: 37 })).status, 201);
    const [ownerProgress, editorProgress] = await Promise.all(
      [owner.accessToken, token].map(async (sessionToken) => {
        const response = await request("books/files/2/progress", sessionToken);
        assert.equal(response.status, 200);
        return response.json();
      }),
    );
    assert.equal(ownerProgress.percentage, 37);
    const createdNote = await request("books/2/annotations", owner.accessToken, {
      cfi: "epubcfi(/6/2!/4/2:0)",
      bookFileId: 2,
      text: "Selected book passage",
      note: "E03 bulk preservation note",
      color: "yellow",
    });
    assert.equal(createdNote.status, 201);
    annotation = await createdNote.json();
    const reviewed = await preview(token, fields);
    assert.deepEqual(
      reviewed.books.map((book) => book.bookId),
      selected,
    );
    assert.deepEqual((await record(unselected, token)).publisher, originals[2].publisher);
    assert.equal((await record(1, token)).publisher, originals[0].publisher, "Preview does not mutate");
    for (const denied of [reader.accessToken, restricted.accessToken]) {
      assert.equal((await request("books/bulk-edit-metadata/preview", denied, { bookIds: selected, fields })).status, 403);
      assert.equal((await request("books/bulk-edit-metadata", denied, { bookIds: selected, fields })).status, 403);
    }
    assert.equal((await request("books/export/preflight", restricted.accessToken, { bookIds: selected })).status, 403);
    assert.equal((await request("books/bulk-edit-metadata/preview", null, { bookIds: selected, fields })).status, 401);
    for (const bad of [
      { bookIds: Array.from({ length: 101 }, (_, i) => i + 1), fields },
      { bookIds: selected, fields: { publisher: {} } },
      { bookIds: selected, fields: { unexpected: { value: "bad" } } },
      { bookIds: selected, fields: { customMetadata: [{ fieldId: 999999, value: "bad" }] } },
    ])
      assert.equal((await request("books/bulk-edit-metadata/preview", token, bad)).status, 400);
    assert.equal((await request("books/1/metadata", token, { publisher: "Newer web edit" }, "PATCH")).status, 200);
    const apply = (review) => request("books/bulk-edit-metadata", token, { bookIds: selected, fields, expectedVersions: versions(review) });
    assert.equal((await apply(reviewed)).status, 409, "Stale preview cannot overwrite newer metadata");
    assert.equal((await record(1, token)).publisher, "Newer web edit");
    assert.equal((await record(2, token)).publisher, originals[1].publisher, "Conflict rolls back whole batch");
    const current = await preview(token, fields);
    const applied = await apply(current);
    assert.equal(applied.status, 201);
    assert.equal((await applied.json()).updatedBooks, 2);
    assert.equal((await apply(current)).status, 409, "Unconfirmed retry cannot reapply old preview");
    assert.equal((await apply(current)).status, 409, "Repeated retry remains rejected");
    const after = await Promise.all([...selected, unselected].map((id) => record(id, token)));
    assert.deepEqual(await (await request("books/files/2/progress", owner.accessToken)).json(), ownerProgress);
    assert.deepEqual(await (await request("books/files/2/progress", token)).json(), editorProgress);
    const ownerNotes = await (
      await request("books/2/annotations?page=1&pageSize=100&search=E03%20bulk%20preservation%20note", owner.accessToken)
    ).json();
    assert.ok(ownerNotes.items.some((item) => item.id === annotation.id && item.note === "E03 bulk preservation note"));
    const editorNotes = await (await request("books/2/annotations?page=1&pageSize=100&search=E03%20bulk%20preservation%20note", token)).json();
    assert.ok(!editorNotes.items.some((item) => item.id === annotation.id), "Another user's private note remains isolated");
    for (const book of after.slice(0, 2)) {
      assert.equal(book.publisher, "E03 Selected Press");
      assert.ok(book.tags.includes("E03 selected batch"));
    }
    assert.equal(after[2].publisher, originals[2].publisher);
    assert.deepEqual(after[2].tags, originals[2].tags);
    for (let i = 0; i < 2; i++) {
      assert.deepEqual(after[i].readStatus, originals[i].readStatus);
      assert.deepEqual(
        after[i].files.map(({ id, sizeBytes }) => ({ id, sizeBytes })),
        originals[i].files.map(({ id, sizeBytes }) => ({ id, sizeBytes })),
      );
    }
    const created = await request("custom-metadata/fields", owner.accessToken, {
      label: "E03 Bulk QA",
      type: "text",
      enabledLibraryIds: [originals[0].libraryId],
    });
    assert.equal(created.status, 201);
    custom = await created.json();
    for (const path of ["books/bulk-edit-metadata/preview", "books/bulk-edit-metadata"])
      assert.equal((await request(path, token, { bookIds: selected, fields: { customMetadata: [{ fieldId: custom.id }] } })).status, 400);
    const customFields = { customMetadata: [{ fieldId: custom.id, value: "Selected custom value" }] };
    const staleCustomPreview = await preview(token, customFields);
    assert.equal(
      (await request("books/1/metadata", token, { customMetadata: [{ fieldId: custom.id, value: "Newer custom web value" }] }, "PATCH")).status,
      200,
    );
    assert.equal(
      (await request("books/bulk-edit-metadata", token, { bookIds: selected, fields: customFields, expectedVersions: versions(staleCustomPreview) }))
        .status,
      409,
    );
    assert.equal((await record(1, token)).customMetadata.find((field) => field.fieldId === custom.id).value, "Newer custom web value");
    const customPreview = await preview(token, customFields);
    assert.equal(
      (await request("books/bulk-edit-metadata", token, { bookIds: selected, fields: customFields, expectedVersions: versions(customPreview) }))
        .status,
      201,
    );
    for (const id of selected)
      assert.equal((await record(id, token)).customMetadata.find((field) => field.fieldId === custom.id).value, "Selected custom value");
    assert.ok(
      !(await record(unselected, token)).customMetadata.some((field) => field.fieldId === custom.id && field.value === "Selected custom value"),
    );
    const json = await request("books/metadata-export/download", token, {
      bookIds: selected,
      format: "json",
      options: { includePersonalData: true, includeContextMeta: true },
    });
    assert.equal(json.status, 200);
    const metadataBytes = Buffer.from(await json.arrayBuffer());
    const metadata = JSON.parse(metadataBytes);
    assert.deepEqual(
      metadata.items.map((item) => item.bookId).sort((a, b) => a - b),
      selected,
    );
    for (const item of metadata.items) {
      assert.equal(item.publisher, "E03 Selected Press");
      assert.ok(Object.entries(item).some(([key, value]) => key.startsWith("custom.") && value === "Selected custom value"));
    }
    const csv = await request("books/metadata-export/download", token, { bookIds: selected, format: "csv" });
    assert.equal(csv.status, 200);
    assert.ok((await csv.text()).includes("E03 Selected Press"));
    const preflight = await request("books/export/preflight", token, { bookIds: selected, allFormats: false });
    assert.equal(preflight.status, 201);
    assert.equal((await preflight.json()).bookCount, 2);
    const archive = await request("books/export", token, { bookIds: selected, allFormats: false });
    assert.equal(archive.status, 200);
    const archiveBytes = Buffer.from(await archive.arrayBuffer());
    const parsed = await unzipper.Open.buffer(archiveBytes);
    assert.equal(parsed.files.filter((file) => file.type === "File").length, 2);
    const exportedDigests = await Promise.all(parsed.files.filter((file) => file.type === "File").map(async (file) => digest(await file.buffer())));
    const deliveredDigests = await Promise.all(
      originals.slice(0, 2).map(async (book) => {
        const file = book.files.find((item) => item.role === "primary") ?? book.files[0];
        const response = await request(`books/files/${file.id}/download`, token);
        assert.equal(response.status, 200);
        return digest(Buffer.from(await response.arrayBuffer()));
      }),
    );
    assert.deepEqual(exportedDigests.sort(), deliveredDigests.sort());
    const artifacts = process.env.IPAD_TEST_ARTIFACTS ?? "test-results/ipad/e03-bulk";
    await mkdir(artifacts, { recursive: true });
    await Promise.all([writeFile(`${artifacts}/selected-books.zip`, archiveBytes), writeFile(`${artifacts}/selected-metadata.json`, metadataBytes)]);
  } finally {
    if (originalOwnerProgress) {
      if (originalOwnerProgress.textUpdatedAt === null && originalOwnerProgress.narrationUpdatedAt === null)
        assert.equal((await request("books/files/2/progress", owner.accessToken, null, "DELETE")).status, 204);
      else
        assert.equal(
          (
            await request("books/files/2/progress", owner.accessToken, {
              cfi: originalOwnerProgress.cfi,
              pageNumber: originalOwnerProgress.pageNumber,
              percentage: originalOwnerProgress.percentage,
              positionSeconds: originalOwnerProgress.positionSeconds,
              mediaOverlayFragment: originalOwnerProgress.mediaOverlayFragment,
              mediaOverlaySectionIndex: originalOwnerProgress.mediaOverlaySectionIndex,
            })
          ).status,
          201,
        );
    }
    if (annotation) assert.equal((await request(`books/2/annotations/${annotation.id}`, owner.accessToken, null, "DELETE")).status, 204);
    for (const original of originals.slice(0, 2)) {
      assert.equal(
        (
          await request(
            `books/${original.id}/metadata`,
            token,
            { publisher: original.publisher, tags: original.tags, ...(custom ? { customMetadata: [{ fieldId: custom.id, value: null }] } : {}) },
            "PATCH",
          )
        ).status,
        200,
      );
    }
    if (custom) assert.equal((await request(`custom-metadata/fields/${custom.id}/permanent`, owner.accessToken, null, "DELETE")).status, 204);
    for (const session of [editor, reader, restricted, owner]) await request("auth/logout", null, { refreshToken: session.refreshToken });
  }
});
