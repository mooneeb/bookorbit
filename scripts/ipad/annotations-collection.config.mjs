import { defineConfig } from "@playwright/test";

const run = process.env.IPAD_TEST_RUN ?? `collection-${Date.now()}`;
if (!/^[a-zA-Z0-9_-]+$/.test(run)) throw new Error("IPAD_TEST_RUN must be a safe directory name");

export default defineConfig({
  testDir: ".",
  testMatch: "annotations-collection.test.mjs",
  workers: 1,
  retries: 0,
  timeout: 180_000,
  expect: { timeout: 5000 },
  outputDir: `../../test-results/ipad/${run}/browser`,
  reporter: [["list"], ["html", { outputFolder: `../../test-results/ipad/${run}/browser-report`, open: "never" }]],
  use: {
    baseURL: "http://localhost:16484",
    browserName: "chromium",
    viewport: { width: 1024, height: 1366 },
    locale: "en-US",
    timezoneId: "UTC",
    colorScheme: "light",
    reducedMotion: "no-preference",
    screenshot: "only-on-failure",
    trace: "retain-on-failure",
  },
});
