import { test, expect } from "@playwright/test";

test("IPAD-E03-A05-entities-web: native entity rename appears in the real web profile and preserves readable source", async ({ page }, info) => {
  const api = process.env.IPAD_API_BASE ?? "http://localhost:16482/api/v1";
  const login = await page.request.post(`${api}/auth/login`, {
    data: { username: "ipad-editor", password: "IpadFixture123", clientKind: "native", deviceLabel: "Entity cross-client control" },
  });
  expect(login.status()).toBe(200);
  const credentials = await login.json();
  const headers = { Authorization: `Bearer ${credentials.accessToken}` };
  const before = await (await page.request.get(`${api}/books/1`, { headers })).json();
  const original = before.authors.map((item) => item.name);
  const marker = `Cross-client entity ${Date.now()}`;
  try {
    expect((await page.request.patch(`${api}/books/1/metadata`, { headers, data: { authors: [marker] } })).status()).toBe(200);
    const browse = await (
      await page.request.get(`${api}/entity-manager/author/browse?search=${encodeURIComponent(marker)}&pageSize=1`, { headers })
    ).json();
    const author = browse.items[0];
    expect(author.bookCount).toBe(1);
    const renamed = `${marker} corrected`;
    const mutation = await page.request.post(`${api}/entity-manager/author/rename`, {
      headers,
      data: { entityId: author.id, newName: renamed, writeFiles: false },
    });
    expect(mutation.status()).toBe(201);
    expect((await mutation.json()).affectedBookCount).toBe(1);
    await page.goto("/login");
    await page.locator("#username").fill("ipad-editor");
    await page.locator("#password").fill("IpadFixture123");
    await page.getByRole("button", { name: "Sign in", exact: true }).click();
    await expect(page).not.toHaveURL(/\/login/);
    await page.goto(`/authors/${author.id}`);
    await expect(page.getByText(renamed, { exact: true }).first()).toBeVisible();
    await expect(page.getByText(before.title, { exact: true }).first()).toBeVisible();
    await page.screenshot({ path: info.outputPath("IPAD-E03-A05-entities-web-renamed-profile.png") });
    await page.goto("/book/1");
    await expect(page.getByText(before.title, { exact: true }).first()).toBeVisible();
    await expect(page.getByText(renamed, { exact: true }).first()).toBeVisible();
    await page.getByRole("button", { name: "Read", exact: true }).click();
    await expect(page.getByRole("spinbutton", { name: "Current page", exact: true })).toBeVisible();
    await page.screenshot({ path: info.outputPath("IPAD-E03-A05-entities-web-reader-preserved.png") });
    const after = await (await page.request.get(`${api}/books/1`, { headers })).json();
    expect(after.files).toEqual(before.files);
  } finally {
    await page.request.patch(`${api}/books/1/metadata`, { headers, data: { authors: original } });
    await page.request.post(`${api}/auth/logout`, { data: { refreshToken: credentials.refreshToken } });
  }
});
