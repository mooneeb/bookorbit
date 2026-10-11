import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { mkdir, readFile, readdir, writeFile } from "node:fs/promises";
import { dirname, join, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { annotationProfile } from "./annotation-matrix.mjs";
import { compareReviewedVisual } from "./annotation-visual.mjs";

const root = fileURLToPath(new URL("../../", import.meta.url));
const baselineRoot = join(root, "ipad/VisualBaselines/E03");
const defaultOutput = join(root, "test-results/ipad/e03-verification/visual-review");
const screenshotPattern = /^(IPAD-E03-(?:A0[1-5]|REQUEST-ADMIN))-(.+)$/;

export async function compareE03Visual(options) {
  assert.match(options.testId, /^IPAD-E03-(?:A0[1-5]|REQUEST-ADMIN)$/);
  return compareReviewedVisual({ baselineRoot, ...options });
}

export function assertE03VisualGate(reports) {
  assert.ok(reports.length > 0, "E03 visual gate requires captured meaningful states");
  const blocked = reports.filter((report) => report.status !== "passed");
  assert.equal(
    blocked.length,
    0,
    `E03 visual gate blocked: ${blocked.map((report) => `${report.testId}/${report.state}/${report.profile.name}: ${report.status}`).join(", ")}`,
  );
}

function screenshotIdentity(name) {
  const screenshotName = name.replace(/_\d+_[A-Fa-f0-9-]+\.png$/, "").replace(/\.png$/, "");
  const match = screenshotName.match(screenshotPattern);
  if (match) return { testId: match[1], state: match[2].replace(/[^a-zA-Z0-9_-]/g, "-"), screenshotName };
  if (name.startsWith("IPAD-E03-permission-scoped-management-navigation")) {
    return { testId: "IPAD-E03-A05", state: "permission-scoped-management-navigation", screenshotName };
  }
}

async function compareCaptures(captures, outputDir) {
  const reports = [];
  for (const capture of captures) {
    const actualPath = resolve(root, capture.sourcePath);
    assert.ok(actualPath.startsWith(`${root}`), "Captured images must belong to this worktree");
    const id = createHash("sha256").update(capture.sourcePath).digest("hex").slice(0, 12);
    const report = await compareE03Visual({
      actualPath,
      outputDir: join(outputDir, capture.surface, capture.profile, id),
      testId: capture.testId,
      state: capture.state,
      surface: capture.surface,
      profile: capture.profile,
      metadata: capture,
    });
    if (capture.inspection?.sha256 && capture.inspection.sha256 !== report.actualSha256) {
      report.status = "failed-inspection-checksum";
      report.reason = "The image changed after recorded agent inspection";
    }
    if (capture.evidenceOnly && report.status !== "failed-inspection-checksum") report.status = "evidence-only";
    reports.push(report);
  }
  return reports;
}

export async function compareNativeE03Visuals(artifacts, profile) {
  let attachmentDirectory = join(artifacts, "native-attachments");
  let manifest;
  try {
    manifest = await readFile(join(attachmentDirectory, "manifest.json"), "utf8");
  } catch (error) {
    if (error.code !== "ENOENT") throw error;
    attachmentDirectory = join(artifacts, "attachments");
    manifest = await readFile(join(attachmentDirectory, "manifest.json"), "utf8");
  }
  const entries = JSON.parse(manifest);
  const captures = [];
  for (const entry of entries) {
    for (const attachment of entry.attachments) {
      const identity = screenshotIdentity(attachment.suggestedHumanReadableName ?? "");
      if (!identity || !attachment.exportedFileName.endsWith(".png")) continue;
      captures.push({
        ...identity,
        sourcePath: relative(root, join(attachmentDirectory, attachment.exportedFileName)),
        surface: "native",
        profile,
        testIdentifier: entry.testIdentifier,
        deviceName: attachment.deviceName,
        deviceId: attachment.deviceId,
        configurationName: attachment.configurationName,
      });
    }
  }
  const reports = await compareCaptures(captures, join(artifacts, "e03-native-visual"));
  await writeFile(join(artifacts, "e03-native-visual-report.json"), `${JSON.stringify(reports, null, 2)}\n`);
  assertE03VisualGate(reports);
  return reports;
}

async function screenshotFiles(directory) {
  const files = [];
  for (const entry of (await readdir(directory, { withFileTypes: true })).sort((a, b) => a.name.localeCompare(b.name, "en"))) {
    const path = join(directory, entry.name);
    if (entry.isDirectory()) files.push(...(await screenshotFiles(path)));
    else if (entry.name.endsWith(".png") && screenshotIdentity(entry.name)) files.push(path);
  }
  return files;
}

export async function compareWebE03Visuals(artifacts, profile) {
  const files = await screenshotFiles(join(artifacts, "e03-browser"));
  const reports = await compareCaptures(
    files.map((path) => ({
      ...screenshotIdentity(path.split("/").at(-1)),
      sourcePath: relative(root, path),
      surface: "web",
      profile,
      viewport: annotationProfile(profile).viewport,
      testArtifactDirectory: relative(root, dirname(path)),
    })),
    join(artifacts, "e03-browser-visual"),
  );
  await writeFile(join(artifacts, "e03-browser-visual-report.json"), `${JSON.stringify(reports, null, 2)}\n`);
  assertE03VisualGate(reports);
  return reports;
}

function matchesScreenshot(template, name) {
  const escaped = template.replace(/[.*+?^${}()|[\]\\]/g, "\\$&").replace(/<[^>]+>/g, "[a-zA-Z0-9_-]+");
  return new RegExp(`^${escaped}$`).test(name.replace(/[^a-zA-Z0-9_-]/g, "-"));
}

function expandState(state, expansion) {
  if (!expansion) return [state];
  let names = [state.name];
  const replacements = [
    ["<type>-<mode>", state.name.endsWith("-source-interrupted") ? ["audiobookshelf-api"] : expansion.migrationModes],
    ["<mode>", expansion.migrationModes],
    ["<provider>", expansion.migrationProviders],
    ["<format>", expansion.mediaFormats],
    ["<reopen>", expansion.reopenIterations],
    ["<id>", expansion.selectedBookIds],
  ];
  for (const [placeholder, values] of replacements) {
    if (values)
      names = names.flatMap((name) => (name.includes(placeholder) ? values.map((value) => name.replace(placeholder, String(value))) : [name]));
  }
  return names.map((name) => ({ ...state, name }));
}

export function missingE03Coverage(manifest, captures) {
  const missing = [];
  const checks = manifest.matrixCoverage ?? manifest.representativeProfiles.map((profile) => ({ profile, allAuthoredStates: true }));
  for (const check of checks) {
    const required = check.allAuthoredStates
      ? manifest.entries.flatMap((entry) => entry.screenshotNames.map((name) => ({ surface: entry.surface, name })))
      : check.states;
    for (const state of required.flatMap((entry) => expandState(entry, manifest.expansion))) {
      if (
        !captures.some(
          (capture) =>
            !capture.evidenceOnly &&
            capture.surface === state.surface &&
            capture.profile === check.profile &&
            matchesScreenshot(state.name, capture.screenshotName ?? `${capture.testId}-${capture.state}`),
        )
      ) {
        missing.push({ profile: check.profile, ...state });
      }
    }
  }
  return missing;
}

function escapeHTML(value) {
  return String(value).replace(/[&<>"']/g, (character) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[character]);
}

async function writeGallery(report, outputDir) {
  const link = (path) => relative(outputDir, path).split("/").map(encodeURIComponent).join("/");
  const cards = report.comparisons.map((entry) => {
    const capture = entry.metadata;
    const config = entry.profile;
    const artifacts = ["actual", "expected", "diff"].filter((kind) => entry[kind]);
    return `<article id="${escapeHTML(`${entry.testId}-${entry.state}`)}">
<h2>${escapeHTML(entry.testId)}: ${escapeHTML(entry.state)}</h2>
<p><strong>${escapeHTML(entry.status)}</strong> | ${escapeHTML(entry.surface)} | ${escapeHTML(config.name)}</p>
<p>${escapeHTML(capture.testIdentifier ?? capture.testTitle ?? "Test identity not recorded")}</p>
<p>${escapeHTML(JSON.stringify({ viewport: capture.viewport, actualPixels: entry.actualDimensions, device: capture.deviceName, orientation: config.orientation, window: config.window, theme: config.colorScheme, textSize: config.dynamicType, reduceMotion: config.reducedMotion }))}</p>
<p>Configuration evidence: ${escapeHTML(capture.profileVerification ?? "not recorded")}</p>
<p>Runtime pins: ${escapeHTML(JSON.stringify(capture.runtimePins ?? "not recorded"))}</p>
${capture.functionalResult ? `<p>Functional summary: <a href="${escapeHTML(link(resolve(root, capture.functionalResult.summaryPath)))}">${escapeHTML(JSON.stringify(capture.functionalResult))}</a></p>` : ""}
<p>Agent inspection: ${escapeHTML(capture.inspection ? `${capture.inspection.inspectedBy}, ${capture.inspection.inspectedAt}, SHA-256 ${capture.inspection.sha256}` : "not recorded")}</p>
<p>${escapeHTML(capture.inspection?.findings ?? "No image inspection is claimed.")}</p>
<p>Baseline decision: ${escapeHTML(capture.inspection?.disposition ?? "pending human review")}</p>
<p>Original: <a href="${escapeHTML(link(resolve(root, capture.sourcePath)))}">${escapeHTML(capture.sourcePath)}</a></p>
<div>${artifacts.map((kind) => `<figure><a href="${escapeHTML(link(entry[kind]))}"><img loading="lazy" src="${escapeHTML(link(entry[kind]))}" alt="${escapeHTML(`${entry.testId} ${entry.state} ${kind}`)}" width="320"></a><figcaption>${kind}</figcaption></figure>`).join("\n")}</div>
</article>`;
  });
  const missing = report.missingStates.map((entry) => `<li>${escapeHTML(`${entry.surface} ${entry.profile}: ${entry.name}`)}</li>`).join("\n");
  await writeFile(
    join(outputDir, "index.html"),
    `<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>E03 visual review gallery</title><body>
<h1>E03 visual review gallery</h1><p><strong>${escapeHTML(report.status)}</strong>. ${report.comparisons.length} captures; ${report.inspectedCaptures} valid agent inspections; ${report.missingStates.length} required states missing. Agent inspection does not approve a baseline.</p>
<p><a href="gate-report.json">Machine report</a> | <a href="${escapeHTML(link(join(baselineRoot, "reviews.json")))}">Human baseline reviews</a> | <a href="${escapeHTML(link(join(root, "docs/ipad/e03-visual-review.md")))}">Matrix, commands and review procedure</a></p>
${cards.join("\n")}<h2>Missing states</h2><ul>${missing}</ul></body></html>\n`,
  );
}

export async function buildE03Gallery({ inventoryPath = join(baselineRoot, "captures.json"), outputDir = defaultOutput } = {}) {
  await mkdir(outputDir, { recursive: true });
  const inventory = JSON.parse(await readFile(inventoryPath, "utf8"));
  const manifest = JSON.parse(await readFile(join(baselineRoot, "manifest.json"), "utf8"));
  const comparisons = await compareCaptures(inventory.entries, outputDir);
  const missingStates = missingE03Coverage(manifest, inventory.entries);
  const inspectionIssues = comparisons
    .filter(
      (entry) =>
        !entry.metadata.inspection?.inspectedBy ||
        !entry.metadata.inspection?.inspectedAt ||
        !entry.metadata.inspection?.findings ||
        entry.metadata.inspection?.method !== "view_image on the original artifact" ||
        entry.metadata.inspection?.sha256 !== entry.actualSha256,
    )
    .map((entry) => ({ testId: entry.testId, state: entry.state, sourcePath: entry.metadata.sourcePath }));
  const report = {
    status:
      comparisons.some((entry) => !entry.metadata.evidenceOnly) &&
      comparisons.filter((entry) => !entry.metadata.evidenceOnly).every((entry) => entry.status === "passed") &&
      missingStates.length === 0 &&
      inspectionIssues.length === 0
        ? "passed"
        : "blocked",
    baselineApproval: "Human review is required; this command never writes baseline PNGs or reviews.json",
    comparisons,
    inspectedCaptures: comparisons.length - inspectionIssues.length,
    inspectionIssues,
    missingStates,
    residualGates: manifest.residualGates,
  };
  await writeFile(join(outputDir, "gate-report.json"), `${JSON.stringify(report, null, 2)}\n`);
  await writeGallery(report, outputDir);
  return report;
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const argumentsList = process.argv.slice(2);
  const argument = (name) => argumentsList.find((value) => value.startsWith(`${name}=`))?.slice(name.length + 1);
  const profile = argument("--profile") ?? "pro13-portrait-light";
  if (argument("--web-artifacts")) {
    await compareWebE03Visuals(resolve(argument("--web-artifacts")), profile);
  } else if (argument("--native-artifacts")) {
    await compareNativeE03Visuals(resolve(argument("--native-artifacts")), profile);
  } else {
    const report = await buildE03Gallery({
      ...(argument("--inventory") ? { inventoryPath: resolve(argument("--inventory")) } : {}),
      ...(argument("--output") ? { outputDir: resolve(argument("--output")) } : {}),
    });
    console.log(
      JSON.stringify({
        status: report.status,
        captures: report.comparisons.length,
        missingStates: report.missingStates.length,
        gallery: join(argument("--output") ?? defaultOutput, "index.html"),
      }),
    );
    if (report.status !== "passed") process.exitCode = 1;
  }
}
