import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { createRequire } from "node:module";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { annotationProfile } from "./annotation-matrix.mjs";

const root = fileURLToPath(new URL("../../", import.meta.url));
const require = createRequire(new URL("../../server/package.json", import.meta.url));
const sharp = require("sharp");
const baselineRoot = join(root, "ipad/VisualBaselines/E02");

export async function compareAnnotationVisual({ actualPath, outputDir, testId, state, surface, profile, metadata = {} }) {
  assert.match(testId, /^IPAD-E02-A0[1-7]$/);
  assert.match(state, /^[a-zA-Z0-9_-]+$/);
  assert.ok(["native", "web"].includes(surface));
  const config = annotationProfile(profile);
  await mkdir(outputDir, { recursive: true });
  const name = `${testId}-${state}`;
  const actual = await readFile(actualPath);
  const actualCopy = join(outputDir, `${name}-actual.png`);
  await writeFile(actualCopy, actual);
  let reviews;
  try {
    reviews = JSON.parse(await readFile(join(baselineRoot, "reviews.json"), "utf8"));
  } catch (error) {
    if (error.code !== "ENOENT") throw error;
  }
  const baseline = reviews?.entries?.find(
    (entry) => entry.testId === testId && entry.state === state && entry.surface === surface && entry.profile === config.name,
  );
  const report = { testId, state, surface, profile: config, actual: actualCopy, metadata, status: "pending-human-baseline" };
  if (baseline) {
    assert.ok(baseline.reviewedBy && baseline.reviewedAt, "A visual baseline requires recorded human review");
    assert.match(baseline.file, /^[a-zA-Z0-9_./-]+\.png$/);
    const expectedPath = resolve(baselineRoot, baseline.file);
    assert.ok(expectedPath.startsWith(`${baselineRoot}/`), "Baseline must stay within its review directory");
    const expected = await readFile(expectedPath);
    assert.equal(createHash("sha256").update(expected).digest("hex"), baseline.sha256, "Reviewed baseline checksum changed");
    report.expected = join(outputDir, `${name}-expected.png`);
    await writeFile(report.expected, expected);
    const [actualPixels, expectedPixels] = await Promise.all(
      [actual, expected].map((bytes) => sharp(bytes).ensureAlpha().raw().toBuffer({ resolveWithObject: true })),
    );
    const { width, height } = actualPixels.info;
    if (width !== expectedPixels.info.width || height !== expectedPixels.info.height) {
      report.status = "failed-dimensions";
      report.actualDimensions = [width, height];
      report.expectedDimensions = [expectedPixels.info.width, expectedPixels.info.height];
    } else {
      const diff = Buffer.alloc(width * height * 4);
      const masks = baseline.masks ?? [];
      for (const mask of masks) {
        assert.ok(
          mask.reason &&
            Object.values(mask)
              .filter((value) => typeof value === "number")
              .every(Number.isInteger),
        );
        assert.ok(
          mask.left >= 0 && mask.top >= 0 && mask.width > 0 && mask.height > 0 && mask.left + mask.width <= width && mask.top + mask.height <= height,
        );
      }
      let changed = 0;
      let compared = 0;
      const threshold = baseline.pixelThreshold ?? 16;
      const ratioBudget = baseline.maxChangedPixelRatio ?? 0.0005;
      assert.ok(threshold >= 0 && threshold <= 32 && ratioBudget >= 0 && ratioBudget <= 0.005);
      for (let index = 0; index < width * height; index++) {
        const x = index % width;
        const y = Math.floor(index / width);
        const masked = masks.some((mask) => x >= mask.left && x < mask.left + mask.width && y >= mask.top && y < mask.top + mask.height);
        const offset = index * 4;
        const differs =
          !masked &&
          [0, 1, 2, 3].some((channel) => Math.abs(actualPixels.data[offset + channel] - expectedPixels.data[offset + channel]) > threshold);
        if (!masked) compared++;
        if (differs) changed++;
        diff[offset] = differs ? 255 : actualPixels.data[offset];
        diff[offset + 1] = differs ? 0 : actualPixels.data[offset + 1];
        diff[offset + 2] = differs ? 255 : actualPixels.data[offset + 2];
        diff[offset + 3] = 255;
      }
      assert.ok(compared > 0, "Masks cannot exclude an entire screenshot");
      report.diff = join(outputDir, `${name}-diff.png`);
      await sharp(diff, { raw: { width, height, channels: 4 } })
        .png()
        .toFile(report.diff);
      report.changedPixelRatio = changed / compared;
      report.maxChangedPixelRatio = ratioBudget;
      report.status = report.changedPixelRatio <= ratioBudget ? "passed" : "failed-pixels";
    }
  }
  await writeFile(join(outputDir, `${name}-review.json`), `${JSON.stringify(report, null, 2)}\n`);
  return report;
}

export async function captureAnnotationVisual(page, info, state) {
  const testId = info.title.match(/IPAD-E02-A0[1-7]/)?.[0];
  assert.ok(testId, "Annotation screenshot title must identify A01 through A07");
  const actualPath = info.outputPath(`${testId}-${state}.png`);
  await page.screenshot({ path: actualPath, animations: "allow" });
  const report = await compareAnnotationVisual({
    actualPath,
    outputDir: info.outputPath("visual"),
    testId,
    state,
    surface: "web",
    profile: process.env.IPAD_E02_PROFILE,
    metadata: { viewport: page.viewportSize(), browser: info.project.use.browserName, locale: info.project.use.locale, url: page.url() },
  });
  await info.attach(`${testId}-${state}-visual-review`, { body: JSON.stringify(report, null, 2), contentType: "application/json" });
  assert.ok(!report.status.startsWith("failed"), `Meaningful visual regression: ${report.status}`);
  return report;
}

export async function compareNativeAnnotationVisuals(artifacts, profile) {
  const entries = JSON.parse(await readFile(join(artifacts, "native-attachments/manifest.json"), "utf8"));
  const reports = [];
  for (const entry of entries) {
    for (const attachment of entry.attachments) {
      const name = attachment.suggestedHumanReadableName?.replace(/_\d+_[A-Fa-f0-9-]+\.png$/, "");
      const match = name?.match(/^(IPAD-E02-A0[1-7])-(.+)$/);
      if (!match || !attachment.exportedFileName.endsWith(".png")) continue;
      reports.push(
        await compareAnnotationVisual({
          actualPath: join(artifacts, "native-attachments", attachment.exportedFileName),
          outputDir: join(artifacts, "native-visual"),
          testId: match[1],
          state: match[2],
          surface: "native",
          profile,
          metadata: {
            testIdentifier: entry.testIdentifier,
            deviceName: attachment.deviceName,
            deviceId: attachment.deviceId,
            configurationName: attachment.configurationName,
          },
        }),
      );
    }
  }
  await writeFile(join(artifacts, "native-visual-report.json"), `${JSON.stringify(reports, null, 2)}\n`);
  assert.ok(reports.length > 0, "Native E02 journeys must capture named screenshots");
  assert.ok(
    reports.every((report) => !report.status.startsWith("failed")),
    "Native E02 visual regression failed; inspect expected/actual/diff artifacts",
  );
  return reports;
}
