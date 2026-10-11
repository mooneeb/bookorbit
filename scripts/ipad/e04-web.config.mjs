import { defineConfig } from "@playwright/test";
import { annotationProfile } from "./annotation-matrix.mjs";

const run = process.env.IPAD_TEST_RUN ?? `e04-web-${Date.now()}`;
if (!/^[a-zA-Z0-9_-]+$/.test(run)) throw new Error("IPAD_TEST_RUN must be a safe directory name");
const selected = process.env.IPAD_E04_CASE;
if (selected && !/^A0[1-5]$/.test(selected)) throw new Error("IPAD_E04_CASE must be A01 through A05");
const profile = annotationProfile(process.env.IPAD_E04_PROFILE);

export default defineConfig({
  testDir: ".",
  testMatch: "e04-web.test.mjs",
  workers: 1,
  retries: 0,
  timeout: 180_000,
  expect: { timeout: 15_000 },
  ...(selected ? { grep: new RegExp(`IPAD-E04-${selected}-web`) } : {}),
  outputDir: `../../test-results/ipad/${run}/e04-browser`,
  reporter: [
    ["list"],
    ["html", { outputFolder: `../../test-results/ipad/${run}/e04-browser-report`, open: "never" }],
    ["json", { outputFile: `../../test-results/ipad/${run}/e04-browser-summary.json` }],
  ],
  use: {
    baseURL: process.env.IPAD_WEB_URL ?? "http://localhost:16504",
    browserName: "chromium",
    viewport: profile.viewport,
    colorScheme: profile.colorScheme,
    reducedMotion: profile.reducedMotion,
    locale: "en-US",
    timezoneId: "UTC",
    screenshot: "only-on-failure",
    trace: "retain-on-failure",
    video: "retain-on-failure",
  },
});
