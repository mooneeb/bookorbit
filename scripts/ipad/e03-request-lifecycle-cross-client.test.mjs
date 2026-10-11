import { test, expect } from "@playwright/test";

const api = process.env.IPAD_API_BASE ?? "http://localhost:16482/api/v1";
const protocol = process.env.IPAD_E03_PROTOCOL_URL ?? "http://127.0.0.1:16502";
const password = process.env.IPAD_FIXTURE_PASSWORD ?? "IpadFixture123";

async function nativeSession(request, username) {
  const response = await request.post(`${api}/auth/login`, {
    data: { username, password, clientKind: "native", deviceLabel: "request browser cross-client" },
  });
  expect(response.status()).toBe(200);
  return response.json();
}
async function call(request, path, token, data, method = data ? "POST" : "GET") {
  return request.fetch(`${api}/${path}`, { method, headers: { Authorization: `Bearer ${token}` }, ...(data ? { data } : {}) });
}
async function signIn(page, username) {
  await page.goto("/login");
  await page.locator("#username").fill(username);
  await page.locator("#password").fill(password);
  await page.getByRole("button", { name: "Sign in", exact: true }).click();
  await expect(page).not.toHaveURL(/\/login/);
}

async function isolateReviewDestination(request, token, item) {
  const dockResponse = await call(request, `book-dock/files/${item.bookDockFileId}`, token);
  expect(dockResponse.status()).toBe(200);
  const dock = await dockResponse.json();
  const reviewed = await call(
    request,
    `book-dock/files/${dock.id}`,
    token,
    {
      expectedUpdatedAt: dock.updatedAt,
      selectedMetadata: { ...dock.selectedMetadata, title: item.title },
    },
    "PATCH",
  );
  expect(reviewed.status()).toBe(200);
  expect((await reviewed.json()).selectedMetadata.title).toBe(item.title);
}

async function fileAndReadExistingRequest(page, request, owner, id, info) {
  const response = await call(request, `book-requests/${id}`, owner.accessToken);
  expect(response.status()).toBe(200);
  const item = await response.json();
  expect(["needs_review", "available"]).toContain(item.status);
  expect(item.selfServe).toBe(true);
  expect(item.userId).toBe(owner.user.id);
  if (item.status === "needs_review") await isolateReviewDestination(request, owner.accessToken, item);
  await signIn(page, "ipad-owner");
  await page.goto(`/requests/${id}`);
  if (item.status === "needs_review") {
    const filed = page.waitForResponse((response) => new URL(response.url()).pathname === `/api/v1/admin/book-requests/${id}/force-file`);
    await page.getByRole("button", { name: "File it anyway", exact: true }).click();
    expect((await filed).status()).toBe(200);
  }
  const bookLink = page.getByRole("link", { name: "Go to book", exact: true });
  await expect(bookLink).toBeVisible({ timeout: 30_000 });
  const finalResponse = await call(request, `book-requests/${id}`, owner.accessToken);
  const final = await finalResponse.json();
  expect(final.status).toBe("available");
  expect(final.matchedBookId).toBeGreaterThan(0);
  await page.screenshot({ path: info.outputPath("IPAD-E03-A02-web-received-book.png") });
  await bookLink.click();
  await expect.poll(() => new URL(page.url()).pathname).toBe(`/book/${final.matchedBookId}`);
  const bookResponse = await call(request, `books/${final.matchedBookId}`, owner.accessToken);
  expect(bookResponse.status()).toBe(200);
  const book = await bookResponse.json();
  const file = book.files.find((item) => item.format === "pdf");
  expect(file).toBeTruthy();
  const artifact = await call(request, `books/files/${file.id}/serve`, owner.accessToken);
  expect(artifact.status()).toBe(200);
  expect((await artifact.body()).subarray(0, 5).toString()).toBe("%PDF-");
  const delivered = page.waitForResponse((response) => new URL(response.url()).pathname === `/api/v1/books/files/${file.id}/serve`);
  await page.getByRole("button", { name: "Read", exact: true }).click();
  expect((await delivered).ok()).toBe(true);
  await expect(page.getByRole("spinbutton", { name: "Current page", exact: true })).toHaveValue("1");
  const firstPage = page.locator('[data-page-index="0"]').first();
  await expect(firstPage).toBeVisible();
  await expect
    .poll(() => firstPage.locator("img").evaluateAll((images) => images.some((image) => image.complete && image.naturalWidth > 0)))
    .toBe(true);
  await page.screenshot({ path: info.outputPath("IPAD-E03-A02-web-readable-PDF.png") });
}

test("IPAD-E03-A02-cross-client: subscriptions, cancellation, source retry and a received PDF stay visible in the real web reader", async ({
  page,
  request,
}, info) => {
  const owner = await nativeSession(request, "ipad-owner");
  if (process.env.IPAD_E03_EXISTING_REQUEST_ID) {
    const id = Number(process.env.IPAD_E03_EXISTING_REQUEST_ID);
    expect(Number.isSafeInteger(id) && id > 0).toBe(true);
    try {
      await fileAndReadExistingRequest(page, request, owner, id, info);
    } finally {
      await request.post(`${api}/auth/logout`, { data: { refreshToken: owner.refreshToken } });
    }
    return;
  }
  const reader = await nativeSession(request, "ipad-reader");
  const restricted = await nativeSession(request, "ipad-restricted");
  const title = `Browser subscription fixture ${Date.now()}`;
  try {
    const librariesResponse = await call(request, "libraries", owner.accessToken);
    expect(librariesResponse.status()).toBe(200);
    const libraries = await librariesResponse.json();
    const destination = libraries.find((library) => library.name === "Fixture library");
    expect(destination).toBeTruthy();
    const createdResponse = await call(request, "book-requests", owner.accessToken, { title, mediaKind: "ebook", targetLibraryId: destination.id });
    expect(createdResponse.status()).toBe(201);
    const created = await createdResponse.json();
    expect(created.subscribed).toBe(false);
    expect(created.request.targetLibraryId).toBe(destination.id);
    const id = created.request.id;
    expect((await call(request, `book-requests/${id}`, restricted.accessToken)).status()).toBe(403);
    const discovery = await call(request, "book-requests/availability", reader.accessToken, { items: [{ title, mediaKind: "ebook" }] });
    expect((await discovery.json())[0].existingRequestId).toBe(id);
    const joinedResponse = await call(request, "book-requests", reader.accessToken, { title, mediaKind: "ebook" });
    expect(joinedResponse.status()).toBe(201);
    const joined = await joinedResponse.json();
    expect(joined.subscribed).toBe(true);
    expect(joined.request.id).toBe(id);
    await signIn(page, "ipad-reader");
    await page.goto(`/requests/${id}`);
    await expect(page.getByText(title, { exact: true }).first()).toBeVisible();
    expect((await call(request, `book-requests/${id}/cancel`, reader.accessToken, {})).status()).toBe(403);
    await page.screenshot({ path: info.outputPath("IPAD-E03-A02-web-subscribed.png") });
    await page.getByRole("button", { name: `More actions for ${title}`, exact: true }).click();
    await page.getByRole("menuitem", { name: "Leave request", exact: true }).click();
    await page.getByRole("dialog").getByRole("button", { name: "Leave request", exact: true }).click();
    await expect.poll(async () => (await call(request, `book-requests/${id}`, reader.accessToken)).status()).toBe(403);
    await page.screenshot({ path: info.outputPath("IPAD-E03-A02-web-unsubscribed.png") });
    const cancelled = await call(request, `book-requests/${id}/cancel`, owner.accessToken, {});
    expect((await cancelled.json()).status).toBe("cancelled");

    await page.context().clearCookies();
    await page.evaluate(() => localStorage.clear());
    await signIn(page, "ipad-owner");
    await page.goto(`/requests/${id}`);
    await expect(page.getByText("Cancelled", { exact: true }).first()).toBeVisible();
    await page.screenshot({ path: info.outputPath("IPAD-E03-A02-web-cancelled.png") });

    const fulfilledResponse = await call(request, "book-requests", owner.accessToken, {
      title: `Browser received fixture ${Date.now()}`,
      mediaKind: "ebook",
      selfServe: true,
      targetLibraryId: 1,
      targetFolderId: 1,
      preferredFormats: ["pdf"],
    });
    expect(fulfilledResponse.status()).toBe(201);
    const { request: fulfilment } = await fulfilledResponse.json();
    await request.get(`${protocol}/control?failSearch=true`);
    await page.goto(`/requests/${fulfilment.id}/releases`);
    await expect
      .poll(async () => {
        const result = await call(request, `book-request-fulfilment/${fulfilment.id}/releases?refresh=true`, owner.accessToken);
        return (await result.json()).indexers.some((source) => !source.ok);
      })
      .toBe(true);
    await expect(page.getByText(/^(search failed|unreachable|timed out)$/).first()).toBeVisible();
    await page.screenshot({ path: info.outputPath("IPAD-E03-A02-web-source-failure.png") });
    await request.get(`${protocol}/control?reset=true`);
    await page.getByRole("button", { name: "Search again", exact: true }).click();
    const grab = page.getByRole("button", { name: "Download release", exact: true });
    await expect(grab).toBeVisible();
    await page.screenshot({ path: info.outputPath("IPAD-E03-A02-web-release-picker.png") });
    await grab.click();
    await expect
      .poll(
        async () => {
          const response = await call(request, `book-requests/${fulfilment.id}`, owner.accessToken);
          return (await response.json()).status;
        },
        { timeout: 90_000 },
      )
      .toMatch(/^(needs_review|available)$/);
    await page.goto(`/requests/${fulfilment.id}`);
    const fileAnyway = page.getByRole("button", { name: "File it anyway", exact: true });
    const reviewResponse = await call(request, `book-requests/${fulfilment.id}`, owner.accessToken);
    const received = await reviewResponse.json();
    if (received.status === "needs_review") {
      await isolateReviewDestination(request, owner.accessToken, received);
      await page.reload();
      await expect(fileAnyway).toBeVisible();
      await page.screenshot({ path: info.outputPath("IPAD-E03-A02-web-import-review.png") });
      await fileAnyway.click();
    }
    const bookLink = page.getByRole("link", { name: "Go to book", exact: true });
    await expect(bookLink).toBeVisible({ timeout: 30_000 });
    const finalResponse = await call(request, `book-requests/${fulfilment.id}`, owner.accessToken);
    const final = await finalResponse.json();
    expect(final.status).toBe("available");
    expect(final.matchedBookId).toBeGreaterThan(0);
    await page.screenshot({ path: info.outputPath("IPAD-E03-A02-web-received-book.png") });
    await bookLink.click();
    await expect.poll(() => new URL(page.url()).pathname).toBe(`/book/${final.matchedBookId}`);
    const bookResponse = await call(request, `books/${final.matchedBookId}`, owner.accessToken);
    const book = await bookResponse.json();
    const file = book.files.find((item) => item.format === "pdf");
    expect(file).toBeTruthy();
    const artifact = await call(request, `books/files/${file.id}/serve`, owner.accessToken);
    expect(artifact.status()).toBe(200);
    expect((await artifact.body()).subarray(0, 5).toString()).toBe("%PDF-");
    const delivered = page.waitForResponse((response) => new URL(response.url()).pathname === `/api/v1/books/files/${file.id}/serve`);
    await page.getByRole("button", { name: "Read", exact: true }).click();
    expect((await delivered).ok()).toBe(true);
    await expect(page.getByRole("spinbutton", { name: "Current page", exact: true })).toHaveValue("1");
    const firstPage = page.locator('[data-page-index="0"]').first();
    await expect(firstPage).toBeVisible();
    await expect
      .poll(() => firstPage.locator("img").evaluateAll((images) => images.some((image) => image.complete && image.naturalWidth > 0)))
      .toBe(true);
    await page.screenshot({ path: info.outputPath("IPAD-E03-A02-web-readable-PDF.png") });
  } finally {
    await request.get(`${protocol}/control?reset=true`);
    for (const session of [owner, reader, restricted]) {
      await request.post(`${api}/auth/logout`, { data: { refreshToken: session.refreshToken } });
    }
  }
});
