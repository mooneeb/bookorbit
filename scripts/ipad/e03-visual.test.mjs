import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { createRequire } from "node:module";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { assertE03VisualGate, compareE03Visual, e03CaptureGeometryIssue, missingE03Coverage } from "./e03-visual.mjs";

test("E03 capture geometry rejects portrait landscape labels and unrecorded narrow bounds", () => {
  assert.equal(e03CaptureGeometryIssue("pro13-portrait-light", "native", [2064, 2752]), null);
  assert.match(e03CaptureGeometryIssue("pro11-landscape-dark", "native", [1668, 2388]), /orientation is portrait/);
  assert.match(e03CaptureGeometryIssue("pro11-landscape-dark", "native", [2388, 1000]), /aspect ratio/);
  assert.match(e03CaptureGeometryIssue("pro13-narrow-dark", "native", [1200, 2048]), /recorded actual window bounds/);
  assert.equal(e03CaptureGeometryIssue("pro13-narrow-dark", "native", [1200, 2048], { windowBounds: { width: 600, height: 1024 } }), null);
  assert.match(e03CaptureGeometryIssue("pro11-landscape-dark", "web", [834, 1194]), /browser bounds/);
  const manifest = { matrixCoverage: [{ profile: "pro11-landscape-dark", states: [{ surface: "native", name: "IPAD-E03-A01-reader" }] }] };
  assert.equal(
    missingE03Coverage(manifest, [
      { surface: "native", profile: "pro11-landscape-dark", testId: "IPAD-E03-A01", state: "reader", geometryVerified: false },
    ]).length,
    1,
  );
});

const require = createRequire(new URL("../../server/package.json", import.meta.url));
const sharp = require("sharp");

async function fixture(t) {
  const directory = await mkdtemp(join(tmpdir(), "bookorbit-e03-visual-comparator-"));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const expected = await sharp({ create: { width: 8, height: 8, channels: 4, background: "white" } })
    .png()
    .toBuffer();
  const actualPath = join(directory, "capture.png");
  await writeFile(actualPath, expected);
  await writeFile(join(directory, "baseline.png"), expected);
  const review = {
    testId: "IPAD-E03-A01",
    state: "isolated-comparator-fixture",
    surface: "web",
    profile: "pro13-portrait-light",
    file: "baseline.png",
    sha256: createHash("sha256").update(expected).digest("hex"),
    reviewType: "human",
    reviewedBy: "Synthetic unit fixture only, no product baseline approval",
    reviewedAt: "2026-10-11T00:00:00Z",
    pixelThreshold: 0,
    maxChangedPixelRatio: 0,
    budgetReason: "Synthetic exact-pixel comparator fixture, outside product baseline storage",
  };
  const saveReviews = (entries) => writeFile(join(directory, "reviews.json"), JSON.stringify({ version: 1, entries }));
  await saveReviews([review]);
  return {
    directory,
    review,
    saveReviews,
    compare: () => compareE03Visual({ ...review, actualPath, baselineRoot: directory, outputDir: join(directory, "output") }),
  };
}

test("E03 reviewed identical pixels pass and retain actual, expected, diff and counts", async (t) => {
  const setup = await fixture(t);
  const report = await setup.compare();
  assert.equal(report.status, "passed");
  assert.equal(report.changedPixels, 0);
  assert.equal(report.comparedPixels, 64);
  assertE03VisualGate([report]);
  for (const kind of ["actual", "expected", "diff"]) assert.ok((await readFile(report[kind])).length > 0);
});

test("E03 meaningful changed pixels fail and preserve all comparison artifacts", async (t) => {
  const setup = await fixture(t);
  await sharp({ create: { width: 8, height: 8, channels: 4, background: "black" } })
    .png()
    .toFile(join(setup.directory, "capture.png"));
  const report = await setup.compare();
  assert.equal(report.status, "failed-pixels");
  assert.equal(report.changedPixelRatio, 1);
  assert.throws(() => assertE03VisualGate([report]), /failed-pixels/);
  for (const kind of ["actual", "expected", "diff"]) assert.ok((await readFile(report[kind])).length > 0);
});

test("E03 dimension mismatch fails and produces a union-sized diff", async (t) => {
  const setup = await fixture(t);
  await sharp({ create: { width: 9, height: 7, channels: 4, background: "white" } })
    .png()
    .toFile(join(setup.directory, "capture.png"));
  const report = await setup.compare();
  assert.equal(report.status, "failed-dimensions");
  assert.deepEqual(report.actualDimensions, [9, 7]);
  assert.deepEqual(report.expectedDimensions, [8, 8]);
  const diff = await sharp(report.diff).metadata();
  assert.deepEqual([diff.width, diff.height], [9, 8]);
  assert.throws(() => assertE03VisualGate([report]), /failed-dimensions/);
});

test("E03 missing, agent-only and unreviewed-budget baselines cannot turn green", async (t) => {
  const setup = await fixture(t);
  await setup.compare();
  await setup.saveReviews([]);
  const missing = await setup.compare();
  assert.equal(missing.status, "pending-human-baseline");
  assert.throws(() => assertE03VisualGate([missing]), /pending-human-baseline/);
  await assert.rejects(readFile(join(setup.directory, "output/IPAD-E03-A01-isolated-comparator-fixture-expected.png")), { code: "ENOENT" });
  for (const review of [
    { ...setup.review, reviewType: "agent" },
    { ...setup.review, pixelThreshold: undefined },
  ]) {
    await setup.saveReviews([review]);
    const unapproved = await setup.compare();
    assert.equal(unapproved.status, "failed-baseline-review");
    assert.throws(() => assertE03VisualGate([unapproved]), /failed-baseline-review/);
  }
  assert.throws(() => assertE03VisualGate([]), /captured meaningful states/);
});

test("E03 detects changed reviewed files without writing approval records", async (t) => {
  const setup = await fixture(t);
  const reviewsBefore = await readFile(join(setup.directory, "reviews.json"));
  await sharp({ create: { width: 8, height: 8, channels: 4, background: "black" } })
    .png()
    .toFile(join(setup.directory, "baseline.png"));
  await assert.rejects(setup.compare(), /Reviewed baseline checksum changed/);
  assert.deepEqual(await readFile(join(setup.directory, "reviews.json")), reviewsBefore);
});

test("E03 coverage distinguishes native, browser, profile and failure-only evidence", () => {
  const manifest = {
    matrixCoverage: [{ profile: "pro11-landscape-dark", states: [{ surface: "native", name: "IPAD-E03-A01-native-reader-<bookID>" }] }],
  };
  const capture = { surface: "native", profile: "pro11-landscape-dark", testId: "IPAD-E03-A01", state: "native-reader-42" };
  assert.deepEqual(missingE03Coverage(manifest, [capture]), []);
  for (const changed of [
    { ...capture, surface: "web" },
    { ...capture, profile: "pro13-portrait-light" },
    { ...capture, evidenceOnly: true },
  ]) {
    assert.equal(missingE03Coverage(manifest, [changed]).length, 1);
  }
});

test("E03 migration coverage requires every declared provider mode", () => {
  const manifest = {
    matrixCoverage: [{ profile: "pro13-portrait-light", states: [{ surface: "web", name: "IPAD-E03-A03-<mode>-web-dry-run" }] }],
    expansion: {
      migrationModes: ["booklore-database", "grimmory-database", "audiobookshelf-api", "audiobookshelf-backup", "calibre_web_automated-snapshot"],
    },
  };
  const capture = { surface: "web", profile: "pro13-portrait-light", testId: "IPAD-E03-A03", state: "booklore-database-web-dry-run" };
  const missing = missingE03Coverage(manifest, [capture]);
  assert.equal(missing.length, 4);
  assert.ok(missing.some((entry) => entry.name.includes("audiobookshelf-backup")));
});
