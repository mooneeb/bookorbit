import { defineConfig } from "@playwright/test";
import { annotationProfile } from "./annotation-matrix.mjs";

const runID = process.env.IPAD_TEST_RUN ?? `e03-manual-${Date.now()}`;
if (!/^[a-zA-Z0-9_-]+$/.test(runID)) throw new Error("IPAD_TEST_RUN must be a safe directory name");
const profile = annotationProfile(process.env.IPAD_E03_PROFILE ?? "pro13-portrait-light");
export default defineConfig({
  testDir: ".",
  testMatch: ["e03-*-web.test.mjs", "e03-*-cross-client.test.mjs"],
  ...(process.env.IPAD_E03_CASE
    ? { grep: new RegExp(`IPAD-E03-${process.env.IPAD_E03_CASE === "A02" ? "(?:A02|REQUEST-ADMIN)" : process.env.IPAD_E03_CASE}`) }
    : {}),
  workers: 1,
  retries: 0,
  timeout: 120_000,
  expect: { timeout: 15_000 },
  outputDir: `../../test-results/ipad/${runID}/e03-browser`,
  reporter: [["list"], ["html", { outputFolder: `test-results/ipad/${runID}/e03-browser-report`, open: "never" }]],
  use: {
    baseURL: "http://localhost:16484",
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
