import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { writeFile } from "node:fs/promises";
import { test, expect } from "@playwright/test";

const execute = promisify(execFile);
async function signIn(page, username = "ipad-reader") {
  await page.goto("/login");
  await page.locator("#username").fill(username);
  await page.locator("#password").fill("IpadFixture123");
  await page.getByRole("button", { name: "Sign in", exact: true }).click();
  await expect(page).not.toHaveURL(/\/login/);
}
async function record(page, path) {
  const response = await page.request.get(`/api/v1/${path}`);
  expect(response.status()).toBe(200);
  return response.json();
}
async function renderedPDF(page, info, state) {
  const pageTwo = page.locator('[data-page-index="1"]').first();
  await expect(pageTwo).toBeInViewport({ ratio: 0.75 });
  await expect
    .poll(() => pageTwo.locator("img").evaluateAll((images) => images.some((image) => image.complete && image.naturalWidth > 0)))
    .toBe(true);
  const path = info.outputPath(`${state}.png`);
  await page.screenshot({ path });
  const { stdout } = await execute("xcrun", ["swift", "scripts/ipad/recognize-text.swift", path], { timeout: 30_000, maxBuffer: 64 * 1024 });
  const recognized = JSON.parse(stdout);
  await writeFile(info.outputPath(`${state}-recognized-text.json`), `${JSON.stringify(recognized, null, 2)}\n`);
  expect(recognized).toContain("Orbit fixture: passage 2");
}

test("IPAD-E01-A01-organization-web: real directories and profiles agree with native selection and resume its actual PDF passage", async ({
  page,
}, info) => {
  await signIn(page);
  const authors = await record(page, "authors?q=Orbit%20author&size=40&page=0&sort=name&order=asc");
  expect(authors.total).toBe(55);
  const author = authors.items[0];
  const series = (await record(page, "series?q=Orbit%20series&size=40&page=0&sort=name&order=asc")).items[0];
  const book = await record(page, "books/1");
  expect(book.id).toBe(1);
  expect(book.files[0].format).toBe("pdf");
  expect(author.name).toBe("Orbit author 000");
  expect(series.name).toBe("Orbit series 000");
  await page.goto("/authors?q=Orbit%20author&sort=name&order=asc");
  await expect(page.getByText(author.name, { exact: true }).first()).toBeVisible();
  await page.screenshot({ path: info.outputPath("IPAD-E01-A01-authors-directory-in-web.png") });
  await page.goto(`/authors/${author.id}`);
  await expect(page.getByText(author.name, { exact: true }).first()).toBeVisible();
  await expect(page.getByText("An author profile for the native organization journey.", { exact: true })).toBeVisible();
  await expect(page.getByText("Science fiction", { exact: true }).first()).toBeVisible();
  await expect(page.getByRole("button", { name: "Edit author", exact: true })).toHaveCount(0);
  await page.screenshot({ path: info.outputPath("IPAD-E01-A01-author-profile-in-web.png") });
  await page.reload();
  await expect(page.getByText(author.name, { exact: true }).first()).toBeVisible();
  await page.goto("/series?q=Orbit%20series&sort=name&order=asc");
  await expect(page.getByText(series.name, { exact: true }).first()).toBeVisible();
  await page.screenshot({ path: info.outputPath("IPAD-E01-A01-series-directory-in-web.png") });
  await page.goto(`/series/${series.id}`);
  await expect(page.getByText(series.name, { exact: true }).first()).toBeVisible();
  await expect(page.getByText("#2, #47", { exact: false }).first()).toBeVisible();
  await expect(page.getByText(book.title, { exact: true }).first()).toBeVisible();
  await page.screenshot({ path: info.outputPath("IPAD-E01-A01-series-profile-in-web.png") });
  const progress = await record(page, "books/files/1/progress");
  expect(progress.pageNumber).toBe(2);
  expect(progress.percentage).toBeCloseTo(66.666667, 3);
  await writeFile(info.outputPath("IPAD-E01-A01-organization-native-progress.json"), `${JSON.stringify(progress, null, 2)}\n`);
  await page.goto("/book/1");
  await expect(page.getByText(book.title, { exact: true }).first()).toBeVisible();
  await page.getByRole("button", { name: "Read", exact: true }).click();
  await expect(page.getByRole("spinbutton", { name: "Current page", exact: true })).toHaveValue("2");
  await renderedPDF(page, info, "IPAD-E01-A01-author-opened-native-page-in-web");
  await page.getByRole("button", { name: "Go back", exact: true }).click();
  await expect(page.getByRole("button", { name: "Read", exact: true })).toBeVisible();
  await page.reload();
  await page.getByRole("button", { name: "Read", exact: true }).click();
  await expect(page.getByRole("spinbutton", { name: "Current page", exact: true })).toHaveValue("2");
  await renderedPDF(page, info, "IPAD-E01-A01-author-opened-native-page-reopened-in-web");
});

test("IPAD-E01-A05-organization-web: the restricted role cannot discover or open the native organization records", async ({ page }, info) => {
  await signIn(page, "ipad-restricted");
  for (const [route, name] of [
    ["authors", "Orbit author 000"],
    ["series", "Orbit series 000"],
  ]) {
    const result = await record(page, `${route}?q=Orbit&size=40&page=0`);
    expect(result.total).toBe(0);
    expect(result.items).toEqual([]);
    await page.goto(`/${route}?q=Orbit`);
    await expect(page.getByText(name, { exact: true })).toHaveCount(0);
    await page.screenshot({ path: info.outputPath(`IPAD-E01-A05-${route}-restricted-in-web.png`) });
  }
  expect((await page.request.get("/api/v1/books/1")).status()).toBe(404);
  expect((await page.request.get("/api/v1/books/files/1/serve")).status()).toBe(403);
});
