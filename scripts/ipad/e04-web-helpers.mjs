import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFile, stat, writeFile, mkdir } from "node:fs/promises";
import { join } from "node:path";
import { expect } from "@playwright/test";
import { annotationProfile } from "./annotation-matrix.mjs";
import { compareReadingSharingVisual } from "./e04-visual.mjs";

const visualReports = new WeakMap();
export const sha256 = (bytes) => createHash("sha256").update(bytes).digest("hex");

export async function nativeHandoff(selected) {
  assert.match(selected, /^A0[1-5]$/);
  const path = process.env.IPAD_E04_NATIVE_STATE_FILE;
  assert.ok(path, "Native cross-client coverage requires IPAD_E04_NATIVE_STATE_FILE from the same isolated native run");
  assert.ok((await stat(path)).size < 262_144, "Native handoff must remain bounded");
  const all = JSON.parse(await readFile(path, "utf8"));
  const value = all[selected];
  assert.ok(value, `Actual native handoff missing for ${selected}`);
  assert.equal(value.testId, `IPAD-E04-${selected}`);
  assert.equal(value.case, selected);
  return value;
}

export async function signIn(page, username) {
  const profile = annotationProfile(process.env.IPAD_E04_PROFILE);
  await page.addInitScript((theme) => localStorage.setItem("theme", JSON.stringify(theme)), profile.colorScheme);
  await page.goto("/login");
  await page.locator("#username").fill(username);
  await page.locator("#password").fill("IpadFixture123");
  const login = page.waitForResponse((response) => response.url().endsWith("/auth/login") && response.request().method() === "POST");
  await page.getByRole("button", { name: "Sign in", exact: true }).click();
  expect((await login).status()).toBe(200);
  await expect(page).not.toHaveURL(/\/login/);
  const account = await json(await page.request.get("/api/v1/auth/me"));
  expect(account.username).toBe(username);
  return account;
}

export async function json(response) {
  expect(response.ok(), `Public HTTP request failed: ${response.status()} ${await response.text()}`).toBe(true);
  return response.json();
}

export async function get(page, path) {
  return json(await page.request.get(`/api/v1/${path}`));
}

export async function saveJSON(info, name, value) {
  const path = info.outputPath(`${name}.json`);
  await writeFile(path, `${JSON.stringify(value, null, 2)}\n`);
  await info.attach(name, { path, contentType: "application/json" });
  return path;
}

export async function reachableControl(page, locator) {
  await expect(locator).toBeVisible();
  await expect(locator).toBeEnabled();
  await locator.scrollIntoViewIfNeeded();
  await locator.focus();
  await expect(locator).toBeFocused();
  const box = await locator.boundingBox();
  const viewport = page.viewportSize();
  expect(box).not.toBeNull();
  expect(box.x).toBeGreaterThanOrEqual(-1);
  expect(box.x + box.width).toBeLessThanOrEqual(viewport.width + 1);
  expect(box.y).toBeGreaterThanOrEqual(-1);
  expect(box.y + box.height).toBeLessThanOrEqual(viewport.height + 1);
}

export async function captureVisual(page, info, state, metadata = {}) {
  const testId = info.title.match(/^IPAD-E04-A0[1-5]/)?.[0];
  assert.ok(testId);
  assert.match(state, /^[a-zA-Z0-9_-]+$/);
  await page.evaluate(() => document.fonts.ready);
  const output = info.outputPath("visual");
  await mkdir(output, { recursive: true });
  const name = `${testId}-${state}`;
  const actualPath = join(output, `${name}-actual.png`);
  await page.screenshot({ path: actualPath, animations: "allow" });
  const report = await compareReadingSharingVisual({
    actualPath,
    outputDir: output,
    testId,
    state,
    surface: "web",
    profile: process.env.IPAD_E04_PROFILE,
    metadata: {
      url: page.url(),
      viewport: page.viewportSize(),
      browser: info.project.use.browserName,
      locale: "en-US",
      timezone: "UTC",
      ...metadata,
    },
  });
  await writeFile(join(output, `${name}-review.json`), `${JSON.stringify(report, null, 2)}\n`);
  await info.attach(name, { path: actualPath, contentType: "image/png" });
  visualReports.set(info, [...(visualReports.get(info) ?? []), report]);
  return report;
}

export async function verifyVisualGate(info) {
  const reports = visualReports.get(info) ?? [];
  await saveJSON(info, "e04-visual-gate", { reports, humanApprovalRequired: true, functionalOnly: process.env.IPAD_E04_FUNCTIONAL_ONLY === "1" });
  if (info.status !== info.expectedStatus) return;
  expect(reports.length, "Every browser journey must capture meaningful visible states").toBeGreaterThan(0);
  expect(
    reports.filter((report) => report.status.startsWith("failed")),
    "Inspect meaningful expected/actual/diff failures",
  ).toEqual([]);
  if (process.env.IPAD_E04_FUNCTIONAL_ONLY !== "1") {
    expect(
      reports.filter((report) => report.status === "pending-human-baseline"),
      "Human-reviewed E04 visual baselines are required; functional-only runs are incomplete evidence",
    ).toEqual([]);
  }
}

export function browserContextOptions(info) {
  const { baseURL, viewport, colorScheme, reducedMotion, locale, timezoneId } = info.project.use;
  return { baseURL, viewport, colorScheme, reducedMotion, locale, timezoneId };
}
