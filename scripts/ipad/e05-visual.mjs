import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { mkdir, readFile, readdir, writeFile } from "node:fs/promises";
import { createRequire } from "node:module";
import { join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { e03CaptureGeometryIssue } from "./e03-visual.mjs";

const root = fileURLToPath(new URL("../../", import.meta.url));
const sharp = createRequire(new URL("../../server/package.json", import.meta.url))("sharp");
const baselineRoot = join(root, "ipad/VisualBaselines/E05");
const identity = (name) => name.match(/^(IPAD-E05-A0[1-6])-(.+?)(?:_\d+_[A-Fa-f0-9-]+)?\.png$/);
const checksum = (bytes) => createHash("sha256").update(bytes).digest("hex");

export async function compareE05Visual({ actualPath, outputDir, testId, state, surface, profile, reviewRoot = baselineRoot }) {
  assert.match(testId, /^IPAD-E05-A0[1-6]$/);
  assert.match(state, /^[a-zA-Z0-9_-]+$/);
  assert.ok(["native", "web"].includes(surface));
  await mkdir(outputDir, { recursive: true });
  const actual = await readFile(actualPath);
  const metadata = await sharp(actual).metadata();
  const stem = `${testId}-${state}`;
  const report = {
    testId,
    state,
    surface,
    profile,
    actual: join(outputDir, `${stem}-actual.png`),
    actualSha256: checksum(actual),
    actualDimensions: [metadata.width, metadata.height],
    status: "pending-human-baseline",
  };
  await writeFile(report.actual, actual);
  let reviews;
  try {
    reviews = JSON.parse(await readFile(join(reviewRoot, "reviews.json"), "utf8"));
  } catch (error) {
    if (error.code !== "ENOENT") throw error;
  }
  const entries =
    reviews?.entries?.filter((entry) => entry.testId === testId && entry.state === state && entry.surface === surface && entry.profile === profile) ??
    [];
  if (entries.length) {
    const baseline = entries[0];
    assert.equal(entries.length, 1, "Each visual state must have one reviewed baseline");
    assert.equal(baseline.reviewType, "human");
    assert.ok(baseline.reviewedBy && Number.isFinite(Date.parse(baseline.reviewedAt)) && baseline.budgetReason);
    assert.ok(Number.isInteger(baseline.pixelThreshold) && baseline.pixelThreshold >= 0 && baseline.pixelThreshold <= 32);
    assert.ok(Number.isFinite(baseline.maxChangedPixelRatio) && baseline.maxChangedPixelRatio >= 0 && baseline.maxChangedPixelRatio <= 0.005);
    const expectedPath = resolve(reviewRoot, baseline.file);
    assert.ok(expectedPath.startsWith(`${resolve(reviewRoot)}/`));
    const expected = await readFile(expectedPath);
    assert.equal(checksum(expected), baseline.sha256, "Human-reviewed baseline changed");
    report.expected = join(outputDir, `${stem}-expected.png`);
    await writeFile(report.expected, expected);
    const [pixels, expectedPixels] = await Promise.all(
      [actual, expected].map((bytes) => sharp(bytes).ensureAlpha().raw().toBuffer({ resolveWithObject: true })),
    );
    if (pixels.info.width !== expectedPixels.info.width || pixels.info.height !== expectedPixels.info.height) report.status = "failed-dimensions";
    else {
      const diff = Buffer.from(pixels.data);
      let changed = 0;
      for (let offset = 0; offset < pixels.data.length; offset += 4) {
        if (
          [0, 1, 2, 3].some((channel) => Math.abs(pixels.data[offset + channel] - expectedPixels.data[offset + channel]) > baseline.pixelThreshold)
        ) {
          changed++;
          diff.set([255, 0, 255, 255], offset);
        }
      }
      report.changedPixelRatio = changed / (pixels.info.width * pixels.info.height);
      report.status = report.changedPixelRatio <= baseline.maxChangedPixelRatio ? "passed" : "failed-pixels";
      report.diff = join(outputDir, `${stem}-diff.png`);
      await sharp(diff, { raw: { width: pixels.info.width, height: pixels.info.height, channels: 4 } })
        .png()
        .toFile(report.diff);
    }
  }
  const geometry = e03CaptureGeometryIssue(profile, surface, report.actualDimensions);
  if (geometry) {
    report.status = "failed-profile-geometry";
    report.reason = geometry;
  }
  await writeFile(join(outputDir, `${stem}-review.json`), `${JSON.stringify(report, null, 2)}\n`);
  return report;
}

async function webFiles(directory) {
  const files = [];
  for (const entry of await readdir(directory, { withFileTypes: true })) {
    const path = join(directory, entry.name);
    if (entry.isDirectory()) files.push(...(await webFiles(path)));
    else if (identity(entry.name)) files.push({ path, name: entry.name });
  }
  return files;
}

export async function compareE05Captures(artifacts, profile, surface) {
  let files;
  if (surface === "native") {
    const folder = join(artifacts, "native-attachments");
    const manifest = JSON.parse(await readFile(join(folder, "manifest.json"), "utf8"));
    files = manifest
      .flatMap((entry) =>
        entry.attachments.map((attachment) => ({
          path: join(folder, attachment.exportedFileName),
          name: `${attachment.suggestedHumanReadableName?.replace(/\.png$/, "")}.png`,
        })),
      )
      .filter((file) => identity(file.name));
  } else files = await webFiles(join(artifacts, "e05-browser"));
  assert.ok(files.length, "E05 visuals require actual screenshots");
  const reports = [];
  for (const file of files) {
    const match = identity(file.name);
    reports.push(
      await compareE05Visual({
        actualPath: file.path,
        outputDir: join(artifacts, `e05-${surface}-visual`, checksum(Buffer.from(file.path)).slice(0, 12)),
        testId: match[1],
        state: match[2],
        surface,
        profile,
      }),
    );
  }
  await writeFile(join(artifacts, `e05-${surface}-visual-report.json`), `${JSON.stringify(reports, null, 2)}\n`);
  assert.equal(
    reports.filter((report) => report.status !== "passed").length,
    0,
    "E05 visual gate requires reviewed passing baselines; inspect the report and images",
  );
  return reports;
}
