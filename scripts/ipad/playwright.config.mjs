import { defineConfig } from "@playwright/test";

const runID = process.env.IPAD_TEST_RUN ?? `manual-${Date.now()}`;
if (!/^[a-zA-Z0-9_-]+$/.test(runID)) throw new Error("IPAD_TEST_RUN must be a safe directory name");
const artifacts = `../../test-results/ipad/${runID}`;

export default defineConfig({
  testDir: ".",
  testMatch: "web.test.mjs",
  workers: 1,
  retries: 0,
  timeout: 60_000,
  outputDir: `${artifacts}/browser`,
  reporter: [["list"], ["html", { outputFolder: `${artifacts}/browser-report`, open: "never" }]],
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
