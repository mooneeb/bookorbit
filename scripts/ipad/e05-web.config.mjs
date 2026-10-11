import { defineConfig } from "@playwright/test";
import { annotationProfile } from "./annotation-matrix.mjs";

const run = process.env.IPAD_TEST_RUN ?? `e05-manual-${Date.now()}`;
if (!/^[a-zA-Z0-9_-]+$/.test(run)) throw new Error("IPAD_TEST_RUN must be a safe directory name");
const profile = annotationProfile(process.env.IPAD_E05_PROFILE ?? "pro13-portrait-light");
export default defineConfig({
  testDir: ".",
  testMatch: "e05-web.test.mjs",
  ...(process.env.IPAD_E05_CASE ? { grep: new RegExp(`IPAD-E05-${process.env.IPAD_E05_CASE}`) } : {}),
  workers: 1,
  retries: 0,
  timeout: 90_000,
  expect: { timeout: 15_000 },
  outputDir: `../../test-results/ipad/${run}/e05-browser`,
  reporter: [["list"], ["html", { outputFolder: `test-results/ipad/${run}/e05-browser-report`, open: "never" }]],
  use: {
    baseURL: process.env.IPAD_WEB_URL ?? "http://localhost:16588",
    browserName: "chromium",
    viewport: profile.viewport,
    locale: "en-US",
    timezoneId: "UTC",
    colorScheme: profile.colorScheme,
    reducedMotion: profile.reducedMotion,
    screenshot: "only-on-failure",
    trace: "retain-on-failure",
  },
});
