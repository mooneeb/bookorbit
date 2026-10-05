import { defineConfig } from "@playwright/test";

export default defineConfig({
  testDir: ".",
  testMatch: "web.test.mjs",
  workers: 1,
  retries: 0,
  timeout: 60_000,
  outputDir: "../../test-results/ipad/browser",
  reporter: [["list"], ["html", { outputFolder: "../../test-results/ipad/browser-report", open: "never" }]],
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
