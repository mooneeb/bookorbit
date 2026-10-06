import { defineConfig } from "@playwright/test";

const runID = process.env.IPAD_TEST_RUN ?? `manual-${Date.now()}`;
if (!/^[a-zA-Z0-9_-]+$/.test(runID)) throw new Error("IPAD_TEST_RUN must be a safe directory name");
const artifacts = `../../test-results/ipad/${runID}`;

export default defineConfig({
  testDir: ".",
  testMatch:
    process.env.IPAD_ORGANIZATION_PROOF === "1"
      ? "organization-cross-client.test.mjs"
      : process.env.IPAD_COMIC_PROOF === "1"
        ? "comic-cross-client.test.mjs"
        : process.env.IPAD_PDF_READER === "1"
          ? "reader-cross-client.test.mjs"
          : process.env.IPAD_READER_PROOF === "1"
            ? process.env.IPAD_READER_PROOF_EPUB
              ? "epub-cross-client.test.mjs"
              : "reader-cross-client.test.mjs"
            : process.env.IPAD_METADATA_CLEARS_PROOF === "1"
              ? "metadata-clears-cross-client.test.mjs"
              : process.env.IPAD_METADATA_PROOF === "1"
                ? "metadata-cross-client.test.mjs"
                : process.env.IPAD_COVER_PROOF === "1"
                  ? "cover-cross-client.test.mjs"
                  : process.env.IPAD_CROSS_CLIENT === "1"
                    ? [
                        "cross-client.test.mjs",
                        "metadata-cross-client.test.mjs",
                        "metadata-clears-cross-client.test.mjs",
                        "cover-cross-client.test.mjs",
                        "reader-cross-client.test.mjs",
                        "organization-cross-client.test.mjs",
                      ]
                    : "web.test.mjs",
  workers: 1,
  retries: 0,
  timeout: 180_000,
  expect: { timeout: 15_000 },
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
