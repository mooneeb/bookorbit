import { execFile, spawn } from "node:child_process";
import { createHash, randomBytes } from "node:crypto";
import { constants, createWriteStream } from "node:fs";
import { copyFile, lstat, mkdir, open, opendir, readFile, readdir, realpath, rename, rm, writeFile } from "node:fs/promises";
import { createRequire } from "node:module";
import { basename, dirname, isAbsolute, join } from "node:path";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";
import { sanitizeLogValue } from "../../server/src/common/utils/log-sanitize.utils.ts";
import { startFaultProxy } from "./fault-proxy.mjs";
import { createCoverFixture } from "./cover-fixture.mjs";
import { annotationProfile } from "./annotation-matrix.mjs";
import { compareNativeAnnotationVisuals } from "./annotation-visual.mjs";
import { compareNativeE03Visuals, compareWebE03Visuals } from "./e03-visual.mjs";
import { waitForNativeOfflineReady } from "./combined-coordination.mjs";
import { readingSharingSelection, assertReadingSharingCoverage } from "./e04-selection.mjs";
import { startE04Receivers } from "./e04-receivers.mjs";
import { compareNativeReadingSharingVisuals } from "./e04-visual.mjs";
import { e03Suites } from "./e03-runner.mjs";
import { startRequestAdminFixture } from "./e03-request-admin-fixture.mjs";
import { seedDuplicateMergeFixture } from "./e03-duplicate-merge-fixture.mjs";
import { startE03ResponseProxy } from "./e03-response-proxy.mjs";

const readingSharingProof = process.argv.includes("--reading-sharing");
const readingSharingCase = readingSharingProof ? process.argv.find((argument) => argument.startsWith("--case="))?.slice(7) : undefined;
const readingSharing = readingSharingProof ? await readingSharingSelection(readingSharingCase) : undefined;
if (process.argv.includes("--list-reading-sharing")) {
  if (!readingSharingProof) throw new Error("--list-reading-sharing requires --reading-sharing");
  console.log(JSON.stringify(readingSharing, null, 2));
  process.exit(0);
}
const apiPort = readingSharingProof ? 16502 : 16482;
const webPort = readingSharingProof ? 16504 : 16484;
const defaultNativeName = readingSharingProof ? "BookOrbit E04 Test iPad" : "BookOrbit Test iPad";
const nativeDestination = process.env.IPAD_TEST_DESTINATION ?? `platform=iOS Simulator,name=${defaultNativeName}`;
const functionalOnly = readingSharingProof && process.argv.includes("--functional-only");
const existingServer = process.argv.find((argument) => argument.startsWith("--existing-server="))?.slice(18);
if (existingServer && (!readingSharingProof || process.argv.includes("--serve"))) {
  throw new Error("--existing-server requires --reading-sharing and attaches to an already retained E04 server");
}
const startedAt = Date.now();
const execute = promisify(execFile);
process.on("uncaughtExceptionMonitor", (error) => {
  console.error(
    `[ipad.harness] [fail] runId=${process.pid} durationMs=${Date.now() - startedAt} errorClass=${error.name} error="${sanitizeLogValue(error.message)}" - isolated acceptance run failed`,
  );
});

const root = fileURLToPath(new URL("../../", import.meta.url));
const require = createRequire(new URL("../../server/package.json", import.meta.url));
const { Client } = require("pg");
const databaseName = `bookorbit_ipad_${process.pid}_e2e`;
const databaseURL = `postgres://bookorbit:bookorbit@localhost:5432/${databaseName}`;
const runID = `run-${process.pid}-${Date.now()}`;
const resumeArtifacts = readingSharingProof && process.argv.includes("--resume-artifacts");
const artifactsRoot = `${root}/test-results/ipad/${resumeArtifacts ? "e04-resume/" : ""}${runID}`;
let commandNumber = 0;
const packageManager = process.env.IPAD_PNPM_EXECUTABLE ?? "pnpm";
const e03Proof = process.argv.includes("--e03");
const skipBuild = process.argv.includes("--skip-build");
if (skipBuild && (!e03Proof || !process.argv.includes("--serve"))) throw new Error("Compiled output reuse requires retained E03 fixture mode");
const reuseNativeBuild = process.argv.includes("--reuse-native-build");
if (reuseNativeBuild && (!e03Proof || !process.argv.includes("--ui"))) throw new Error("Joined native build reuse requires E03 UI mode");
const e03Case = process.argv.find((argument) => argument.startsWith("--e03-case="))?.slice(11);
const browserConfig = readingSharingProof
  ? "scripts/ipad/e04-web.config.mjs"
  : e03Proof
    ? "scripts/ipad/e03-web.config.mjs"
    : "scripts/ipad/playwright.config.mjs";
if (e03Case && !e03Proof) throw new Error("--e03-case requires --e03");
if (e03Proof) await e03Suites(e03Case);
if (process.argv.includes("--list-e03")) {
  console.log(JSON.stringify({ cases: ["A01", "A02", "A03", "A04", "A05"], suites: await e03Suites(e03Case) }, null, 2));
  process.exit(0);
}
const annotationsProof = process.argv.includes("--annotations");
if (e03Proof && (annotationsProof || readingSharingProof))
  throw new Error("E03 acquisition, E02 annotation and E04 reading-sharing journeys run separately");
const annotationVisualProfile = annotationProfile(process.argv.find((argument) => argument.startsWith("--profile="))?.slice(10));
const nativeVisualProfile = annotationProfile(annotationVisualProfile.nativeProfile ?? annotationVisualProfile.name);
const nativeOnly = process.argv.includes("--native-only");
const preparedNativeBuild = process.argv.find((argument) => argument.startsWith("--prepared-native-build="))?.slice(24);
const incrementalNativeBuild = process.argv.includes("--incremental-native-build");
if (nativeOnly && ((!annotationsProof && !readingSharingProof) || !process.argv.includes("--ui") || process.argv.includes("--web"))) {
  throw new Error("--native-only requires --annotations or --reading-sharing with --ui and runs a focused native seam");
}
if (preparedNativeBuild && (!readingSharingProof || !nativeOnly || !existingServer || !process.env.IPAD_TEST_ONLY)) {
  throw new Error("--prepared-native-build requires a retained E04 native-only run with exact IPAD_TEST_ONLY selectors");
}
if (incrementalNativeBuild && !preparedNativeBuild) {
  throw new Error("--incremental-native-build requires prior actual profile evidence through --prepared-native-build");
}
const annotationCase = readingSharingProof ? undefined : process.argv.find((argument) => argument.startsWith("--case="))?.slice(7);
const combinedRecovery = annotationsProof && annotationCase === "QA456";
const qa5BrowserOnly = process.argv.includes("--qa5-browser-only");
if (
  qa5BrowserOnly &&
  (!annotationsProof ||
    !process.argv.includes("--web") ||
    process.argv.includes("--ui") ||
    nativeOnly ||
    annotationCase ||
    process.argv.includes("--serve") ||
    process.env.IPAD_TEST_ONLY)
) {
  throw new Error("--qa5-browser-only requires --annotations --web without native/case/retained-server overrides");
}
const recordedLayout = process.argv.includes("--recorded-layout");
const pdfHandoff = process.argv.includes("--pdf-handoff");
const pdfRecovery = process.argv.includes("--pdf-recovery");
if (
  recordedLayout &&
  (!annotationsProof ||
    !nativeOnly ||
    annotationCase ||
    pdfHandoff ||
    pdfRecovery ||
    annotationVisualProfile.name !== "pro13-portrait-light" ||
    process.argv.includes("--serve") ||
    process.env.IPAD_TEST_ONLY)
) {
  throw new Error(
    "--recorded-layout requires --annotations --ui --native-only --profile=pro13-portrait-light without case/selector/retained-server overrides",
  );
}
if (
  pdfHandoff &&
  (!annotationsProof ||
    !nativeOnly ||
    annotationCase ||
    recordedLayout ||
    pdfRecovery ||
    qa5BrowserOnly ||
    annotationVisualProfile.name !== "pro13-portrait-light" ||
    process.argv.includes("--serve") ||
    process.env.IPAD_TEST_ONLY)
) {
  throw new Error(
    "--pdf-handoff requires --annotations --ui --native-only --profile=pro13-portrait-light without case/selector/retained-server overrides",
  );
}
if (
  pdfRecovery &&
  (!annotationsProof ||
    !nativeOnly ||
    annotationCase ||
    recordedLayout ||
    pdfHandoff ||
    qa5BrowserOnly ||
    annotationVisualProfile.name !== "pro13-portrait-light" ||
    [
      "--serve",
      "--progress-only",
      "--cross-client",
      "--metadata-proof",
      "--metadata-clears-proof",
      "--cover-proof",
      "--reader-proof",
      "--epub-proof",
      "--comic-proof",
      "--organization-proof",
      "--pdf-reader",
      "--inspect-web",
    ].some((flag) => process.argv.includes(flag)) ||
    process.env.IPAD_TEST_ONLY)
) {
  throw new Error(
    "--pdf-recovery requires --annotations --ui --native-only --profile=pro13-portrait-light without other journey/selector/retained-server overrides",
  );
}
const isolatedNative = combinedRecovery || recordedLayout || pdfHandoff || pdfRecovery;
const recordedLayoutNative = "BookOrbitUITests/AnnotationJourneyTests/testRecordedColdCachedCrossChapterSurvivesLayoutTransition";
const pdfHandoffNative = "BookOrbitUITests/AnnotationJourneyTests/testCachedPDFCloseReturnsOfflineLibrary";
const pdfRecoveryNative = "BookOrbitUITests/AnnotationJourneyTests/testDeletedPDFRetainedExportSurvivesRestart";
const annotationConcurrent =
  annotationsProof && ["A05", "QA456"].includes(annotationCase) && process.argv.includes("--ui") && process.argv.includes("--web");
if (annotationCase && (!annotationsProof || !/^(?:A0[1-7]|QA456)$/.test(annotationCase))) {
  throw new Error("--case requires --annotations and one of A01 through A07 or QA456");
}
if (process.argv.includes("--list-annotations")) {
  console.log(
    "IPAD-E02-A01 passage notes\nIPAD-E02-A02 source PDF publication\nIPAD-E02-A03 source ink edits and Undo\nIPAD-E02-A04 explicit offline resources\nIPAD-E02-A05 concurrent reconciliation\nIPAD-E02-A06 source recovery\nIPAD-E02-A07 annotation hub\nIPAD-E02-QA456 combined offline reading and recovery",
  );
  process.exit(0);
}
if (
  combinedRecovery &&
  (!annotationConcurrent ||
    annotationVisualProfile.name !== "pro13-portrait-light" ||
    nativeOnly ||
    process.argv.includes("--serve") ||
    process.env.IPAD_TEST_ONLY)
) {
  throw new Error("QA456 requires --annotations --ui --web --profile=pro13-portrait-light without selector overrides or retained-server modes");
}
let currentNativeDeviceID;
const combinedNative = "BookOrbitUITests/AnnotationJourneyTests/testIPADE02QA456OfflineReadAlongAndAuthoritativeRecovery";
const combinedNativePreparationBudgetMs = 180_000;
const combinedNativeExecutionAllowanceMs = 900_000;
const combinedNativeExecutionBudgetMs = combinedNativeExecutionAllowanceMs + 60_000;
const combinedNativeEvidenceBudgetMs = 120_000;
const combinedFaultPort = readingSharingProof ? 16505 : isolatedNative ? 16585 + (process.pid % 1000) : 16485;
if (process.argv.includes("--list-journey")) {
  if (!isolatedNative) throw new Error("--list-journey requires --case=QA456, --recorded-layout, --pdf-handoff or --pdf-recovery");
  if (recordedLayout || pdfHandoff || pdfRecovery) {
    console.log(
      JSON.stringify({ native: [pdfRecovery ? pdfRecoveryNative : pdfHandoff ? pdfHandoffNative : recordedLayoutNative], browser: [] }, null, 2),
    );
    process.exit(0);
  }
  console.log(
    JSON.stringify(
      { native: [combinedNative], browser: ["IPAD-E02-QA456-web: one browser collaborates with the combined offline recovery journey"] },
      null,
      2,
    ),
  );
  process.exit(0);
}
const progressOnly = process.argv.includes("--progress-only");
if (progressOnly && ["--ui", "--web", "--serve", "--annotations"].some((flag) => process.argv.includes(flag))) {
  throw new Error("Focused progress HTTP verification runs without UI, browser or retained-server modes");
}
const crossClient = process.argv.includes("--cross-client");
const metadataProof = process.argv.includes("--metadata-proof");
const metadataClearsProof = process.argv.includes("--metadata-clears-proof");
const coverProof = process.argv.includes("--cover-proof");
const readerProof = process.argv.includes("--reader-proof");
if (readingSharingProof && [annotationsProof, readerProof, crossClient, metadataProof, metadataClearsProof, coverProof, progressOnly].some(Boolean))
  throw new Error("E04 runs independently of earlier ticket journeys");
if (annotationsProof && (readerProof || process.argv.includes("--cross-client"))) {
  throw new Error("Annotation acceptance uses the production app in its own focused run");
}
const epubProof = process.argv.includes("--epub-proof");
const comicProof = process.argv.includes("--comic-proof");
const organizationProof = process.argv.includes("--organization-proof");
const pdfReader = process.argv.includes("--pdf-reader");
const inspectWeb = process.argv.includes("--inspect-web");
if (inspectWeb && !process.argv.includes("--web")) throw new Error("Browser inspection requires --web");
const nativeScheme = readingSharingProof
  ? "BookOrbitReadingSharing"
  : readerProof
    ? "BookOrbitReaderProof"
    : annotationsProof
      ? "BookOrbitAnnotations"
      : "BookOrbit";
const nativeTestBundle = readerProof ? "BookOrbitReaderProofUITests" : "BookOrbitUITests";
if (readerProof && (!process.argv.includes("--ui") || crossClient)) {
  throw new Error("Reader proof requires --ui and runs separately from the production cross-client gate");
}
if (epubProof && !readerProof) throw new Error("EPUB proof requires the separate reader proof target");
if (comicProof && (!readerProof || epubProof || !process.argv.includes("--web"))) {
  throw new Error("Comic proof requires the separate reader proof target and --web, without --epub-proof");
}
if (crossClient && (!process.argv.includes("--ui") || !process.argv.includes("--web"))) {
  throw new Error("Cross-client verification requires both --ui and --web");
}
if (
  (metadataProof || metadataClearsProof || coverProof || pdfReader || organizationProof) &&
  (!process.argv.includes("--ui") || !process.argv.includes("--web") || readerProof)
) {
  throw new Error("Focused verification requires the production app with --ui and --web");
}
if ([metadataProof, metadataClearsProof, coverProof, pdfReader, organizationProof].filter(Boolean).length > 1)
  throw new Error("Select one focused journey");
let nativeTests =
  (combinedRecovery
    ? [combinedNative]
    : recordedLayout
      ? [recordedLayoutNative]
      : pdfHandoff
        ? [pdfHandoffNative]
        : pdfRecovery
          ? [pdfRecoveryNative]
          : process.env.IPAD_TEST_ONLY?.split(",")) ??
  (readingSharingProof
    ? readingSharing.native
    : annotationsProof
      ? ["BookOrbitUITests/AnnotationJourneyTests", "BookOrbitUITests/AnnotationHubJourneyTests"]
      : []);
if (nativeTests.some((name) => !new RegExp(`^${nativeTestBundle}/[A-Za-z_]\\w*(?:/[A-Za-z_]\\w*)?$`).test(name))) {
  throw new Error(`IPAD_TEST_ONLY must contain comma-separated ${nativeTestBundle} classes or methods`);
}
if (preparedNativeBuild && nativeTests.some((name) => name.split("/").length !== 3)) {
  throw new Error("Prepared E04 runs require exact method selectors rather than entire test classes");
}
const env = {
  ...process.env,
  DATABASE_URL: databaseURL,
  E2E_DATABASE_URL: databaseURL,
  NODE_ENV: "test",
  APP_URL: `http://localhost:${webPort}`,
  IPAD_E04: readingSharingProof ? "1" : "0",
  IPAD_E04_PROOF: readingSharingProof ? "1" : "0",
  IPAD_E04_API_PORT: String(apiPort),
  IPAD_E04_API_URL: `http://127.0.0.1:${apiPort}/api/v1`,
  IPAD_E04_HTTP_BASE: `http://127.0.0.1:${apiPort}/api/v1`,
  IPAD_E04_BASE_URL: `http://127.0.0.1:${apiPort}`,
  IPAD_E04_SERVER_URL: `http://127.0.0.1:${apiPort}`,
  IPAD_E04_NATIVE_SERVER_URL: `http://127.0.0.1:${apiPort}`,
  IPAD_E04_CASE: readingSharingCase ?? "",
  IPAD_E04_PROFILE: annotationVisualProfile.name,
  IPAD_E04_FAULT_URL: `http://127.0.0.1:${combinedFaultPort}`,
  IPAD_E04_ARTIFACTS_DIR: artifactsRoot,
  IPAD_E04_RESTART_DIRECTORY: `${artifactsRoot}/core-restart`,
  IPAD_KOBO_QUERY_OBSERVER: `${artifactsRoot}/kobo-query-observer.json`,
  IPAD_KOBO_SCALE_FIXTURE: readingSharingProof ? "1" : "0",
  IPAD_E04_ACTIVITY_FIXTURES: readingSharingProof ? "1" : "0",
  IPAD_HARNESS_REPOSITORY_ROOT: root,
  IPAD_E04_NATIVE_STATE_FILE: `${artifactsRoot}/native-state.json`,
  IPAD_E04_EXPECT_NATIVE: readingSharingProof && process.argv.includes("--ui") ? "1" : "0",
  IPAD_E04_FUNCTIONAL_ONLY: functionalOnly ? "1" : "0",
  IPAD_WEB_URL: `http://localhost:${webPort}`,
  IPAD_READING_RECORD_API_URL: `http://127.0.0.1:${apiPort}/api/v1`,
  IPAD_TEST_RUN: runID,
  IPAD_TEST_ARTIFACTS: artifactsRoot,
  IPAD_E03_PROOF: e03Proof ? "1" : "0",
  IPAD_E03_CASE: e03Case ?? "",
  IPAD_E03_PROFILE: annotationVisualProfile.name,
  IPAD_E03_API_URL: "http://localhost:16482/api/v1",
  IPAD_E03_BASE_URL: "http://localhost:16482/api/v1",
  IPAD_API_BASE: "http://localhost:16482/api/v1",
  IPAD_FIXTURE_PASSWORD: "IpadFixture123",
  IPAD_E03_FIXTURE_FILE: `${artifactsRoot}/e03-fixture.json`,
  IPAD_E03_UPLOAD_RECEIPT_FILE: `${artifactsRoot}/e03-upload-receipt.json`,
  IPAD_E03_RECOVERY_RUN_ID: e03Proof ? runID : "",
  ...(e03Proof ? { BOOK_REQUEST_ENCRYPTION_KEY: randomBytes(32).toString("hex"), MIGRATION_IMPORT_ROOT: `${artifactsRoot}/migration-source` } : {}),
  IPAD_ANNOTATIONS_PROOF: annotationsProof ? "1" : "0",
  IPAD_QA5_BROWSER_ONLY: qa5BrowserOnly ? "1" : "0",
  IPAD_RECORDED_LAYOUT_ONLY: recordedLayout ? "1" : "0",
  TEST_RUNNER_IPAD_RECORDED_LAYOUT_ONLY: recordedLayout ? "1" : "0",
  IPAD_PDF_HANDOFF_ONLY: pdfHandoff ? "1" : "0",
  TEST_RUNNER_IPAD_PDF_HANDOFF_ONLY: pdfHandoff ? "1" : "0",
  IPAD_PDF_RECOVERY_ONLY: pdfRecovery ? "1" : "0",
  TEST_RUNNER_IPAD_PDF_RECOVERY_ONLY: pdfRecovery ? "1" : "0",
  IPAD_ANNOTATION_CASE: annotationCase ?? "",
  IPAD_ANNOTATION_FAULT_URL: `http://127.0.0.1:${combinedFaultPort}`,
  TEST_RUNNER_IPAD_ANNOTATION_FAULT_URL: `http://127.0.0.1:${combinedFaultPort}`,
  TEST_RUNNER_IPAD_ANNOTATION_SERVER_URL: `http://127.0.0.1:${apiPort}`,
  IPAD_E02_PROFILE: annotationVisualProfile.name,
  IPAD_E02_CONCURRENT_NATIVE: annotationConcurrent ? "1" : "0",
  IPAD_E02_EXPECT_NATIVE:
    annotationsProof && process.argv.includes("--ui") && process.argv.includes("--web") && (!annotationCase || annotationCase === "A01") ? "1" : "0",
  TEST_RUNNER_IPAD_E02_CONCURRENT_NATIVE: annotationConcurrent ? "1" : "0",
  IPAD_PROGRESS_ONLY: progressOnly ? "1" : "0",
  IPAD_PROGRESS_API_URL: `http://localhost:${progressOnly ? 16487 : 16482}/api/v1`,
  IPAD_CROSS_CLIENT: crossClient ? "1" : "0",
  IPAD_METADATA_PROOF: metadataProof ? "1" : "0",
  IPAD_METADATA_CLEARS_PROOF: metadataClearsProof ? "1" : "0",
  IPAD_COVER_PROOF: coverProof ? "1" : "0",
  IPAD_COVER_FIXTURE_DIR: `${root}/test-results/ipad/${runID}/cover-fixture`,
  IPAD_READER_PROOF: readerProof ? "1" : "0",
  IPAD_COMIC_PROOF: comicProof ? "1" : "0",
  IPAD_ORGANIZATION_PROOF: organizationProof ? "1" : "0",
  IPAD_PDF_READER: pdfReader ? "1" : "0",
  ...(epubProof || annotationsProof || readingSharingProof || e03Proof
    ? { IPAD_READER_PROOF_EPUB: `${root}/test-results/ipad/${runID}/reader-fixture/reader-proof.epub` }
    : {}),
  JWT_SECRET: randomBytes(32).toString("hex"),
  SETUP_BOOTSTRAP_TOKEN: "",
  NATIVE_REDIRECT_URI: "bookorbit://oauth2-callback",
  NATIVE_ADDITIONAL_REDIRECT_URIS: "bookorbit-private://oauth2-callback",
};

async function command(cmd, args, { capture = false, timeoutMs, signal, ...options } = {}) {
  if (interrupted) throw new Error("iPad harness interrupted");
  signal?.throwIfAborted();
  await mkdir(`${artifactsRoot}/logs`, { recursive: true });
  const log = createWriteStream(`${artifactsRoot}/logs/${String(++commandNumber).padStart(3, "0")}-${basename(cmd)}.log`);
  return new Promise((resolve, reject) => {
    let output = "";
    const child = launch(cmd, args, { stdio: ["ignore", "pipe", "pipe"], ...options });
    let timedOut = false;
    let aborted = false;
    let killTimeout;
    const abort = () => {
      aborted = true;
      signalGroup(child, "SIGTERM");
      killTimeout = setTimeout(() => signalGroup(child, "SIGKILL"), 5_000);
    };
    signal?.addEventListener("abort", abort, { once: true });
    if (signal?.aborted) abort();
    const timeout =
      timeoutMs &&
      setTimeout(() => {
        timedOut = true;
        signalGroup(child, "SIGTERM");
        killTimeout = setTimeout(() => signalGroup(child, "SIGKILL"), 5_000);
      }, timeoutMs);
    child.stdout.pipe(log, { end: false });
    child.stderr.pipe(log, { end: false });
    child.stderr.pipe(process.stderr, { end: false });
    if (!capture) child.stdout.pipe(process.stdout, { end: false });
    if (capture) {
      child.stdout.setEncoding("utf8");
      child.stdout.on("data", (chunk) => {
        output += chunk;
        if (output.length > 1_000_000) {
          signalGroup(child, "SIGTERM");
          reject(new Error(`${cmd} exceeded the captured-output limit`));
        }
      });
    }
    child.once("error", (error) => {
      signal?.removeEventListener("abort", abort);
      clearTimeout(timeout);
      clearTimeout(killTimeout);
      log.end();
      reject(error);
    });
    child.once("close", (code, closeSignal) => {
      signal?.removeEventListener("abort", abort);
      clearTimeout(timeout);
      clearTimeout(killTimeout);
      children.delete(child);
      log.end(() => {
        if (aborted) reject(signal.reason ?? new Error(`${cmd} aborted`));
        else if (timedOut) reject(new Error(`${cmd} exceeded ${timeoutMs}ms`));
        else if (code === 0) resolve(output);
        else reject(new Error(`${cmd} failed (${code ?? closeSignal})`));
      });
    });
  });
}

async function publicExportDirectory(deviceID, { create = false } = {}) {
  const container = (
    await command("xcrun", ["simctl", "get_app_container", deviceID, "com.mooneeb.bookorbit.private", "data"], {
      capture: true,
      timeoutMs: 15_000,
    })
  ).trim();
  if (!isAbsolute(container) || container.includes("\n") || !/\/Containers\/Data\/Application\/[A-Fa-f0-9-]+$/.test(container))
    throw new Error("Installed production app did not resolve to a simulator data container");
  const canonicalContainer = await realpath(container);
  const directory = join(canonicalContainer, "Documents");
  if (create) await mkdir(directory, { recursive: true });
  const information = await lstat(directory);
  if (!information.isDirectory() || information.isSymbolicLink() || dirname(await realpath(directory)) !== canonicalContainer)
    throw new Error("Native export directory must be the installed app's public Documents directory");
  return directory;
}

async function nativeBuildBinaries() {
  const products = join(root, "ipad/DerivedDataE04/Build/Products/Debug-iphonesimulator");
  const binaries = [];
  for (const filename of [
    "BookOrbit.app/BookOrbit",
    "BookOrbit.app/BookOrbit.debug.dylib",
    "BookOrbitUITests-Runner.app/PlugIns/BookOrbitUITests.xctest/BookOrbitUITests",
  ]) {
    const path = join(products, filename);
    const information = await lstat(path);
    if (!information.isFile() || information.isSymbolicLink() || information.size > 128 * 1024 * 1024)
      throw new Error("Native build evidence requires bounded regular production app and test binaries");
    binaries.push({
      filename,
      bytes: information.size,
      modifiedAt: information.mtimeMs,
      sha256: createHash("sha256")
        .update(await readFile(path))
        .digest("hex"),
    });
  }
  return binaries;
}

async function validatePreparedNativeBuild(deviceID) {
  const source = await realpath(preparedNativeBuild);
  if (
    !/^run-\d+-\d+$/.test(basename(source)) ||
    ![join(root, "test-results/ipad"), join(root, "test-results/ipad/e04-resume")].includes(dirname(source))
  )
    throw new Error("Prepared native evidence must belong to a completed harness run in this checkout");
  const summary = JSON.parse(await readFile(join(source, "profile-summary.json"), "utf8"));
  const profile = JSON.parse(await readFile(join(source, "native-profile.json"), "utf8"));
  if (
    summary.totalTestCount !== 1 ||
    summary.passedTests !== 1 ||
    summary.failedTests !== 0 ||
    summary.skippedTests !== 0 ||
    summary.expectedFailures !== 0 ||
    !Number.isFinite(summary.finishTime) ||
    profile.deviceID !== deviceID ||
    profile.appliedProfile !== nativeVisualProfile.name ||
    profile.reduceMotion?.verified !== true ||
    profile.reduceMotion.expected !== (nativeVisualProfile.reducedMotion === "reduce")
  )
    throw new Error("Prepared native build requires a passed system-profile preflight on this device and profile");
  const binaries = await nativeBuildBinaries();
  const provenance = await readFile(join(source, "native-build-provenance.json"), "utf8")
    .then(JSON.parse)
    .catch((error) => {
      if (error.code === "ENOENT") return undefined;
      throw error;
    });
  if (!incrementalNativeBuild) {
    if (provenance?.compiledAt) {
      if (
        binaries.some(
          (binary) =>
            !provenance.binaries?.some(
              (record) => record.filename === binary.filename && record.bytes === binary.bytes && record.sha256 === binary.sha256,
            ),
        )
      )
        throw new Error("Prepared native binaries differ from their successful incremental build evidence");
    } else if (binaries.some((binary) => binary.modifiedAt > summary.finishTime * 1000)) {
      throw new Error("Prepared native binaries changed after their successful profile execution");
    }
  }
  return {
    source,
    profile,
    binaries,
    compiledAt: provenance?.compiledAt,
    buildEvidence: provenance?.buildEvidence,
    profileEvidence: isAbsolute(profile.profileEvidence ?? "") ? profile.profileEvidence : join(source, "profile.xcresult"),
    workingTreeEditsAfterProfileIncluded: Boolean(provenance?.compiledAt),
    workingTreeEditsAfterBuildIncluded: false,
    profilePreflight: "reused prior actual passing profile",
  };
}

async function collectNativeFiles(directory, artifacts, requireRecovery, requirePlugin = false) {
  const collectionStartedAt = Date.now();
  console.log(`[ipad.ui_exports] [start] runId=${runID} requireRecovery=${requireRecovery} - collecting public Files exports`);
  const destination = join(artifacts, "native-files");
  await mkdir(destination, { recursive: true });
  const manifest = [];
  let examined = 0;
  let totalBytes = 0;
  for await (const entry of await opendir(directory)) {
    if (++examined > 256) throw new Error("Public Documents export scan exceeded 256 entries");
    const sourcePDF = /^Deleted source A06-[A-Fa-f0-9-]+\.pdf$/.test(entry.name);
    const pluginZIP = entry.name === "bookorbit.koplugin.zip";
    if (
      !sourcePDF &&
      !pluginZIP &&
      !/^RecoveryUI-[A-Fa-f0-9-]+-recovery\.json$/.test(entry.name) &&
      !/^A05-qa456-(?:before|after)-[A-Fa-f0-9-]+\.json$/.test(entry.name) &&
      !/^BookOrbit reading recovery.*\.json$/.test(entry.name) &&
      !/^BookOrbit annotations.*\.json$/.test(entry.name)
    )
      continue;
    const source = join(directory, entry.name);
    const information = await lstat(source);
    if (!information.isFile() || information.isSymbolicLink() || dirname(await realpath(source)) !== directory)
      throw new Error("Native Files export must be a regular public Documents file");
    if (information.size > 16 * 1024 * 1024 || totalBytes + information.size > 64 * 1024 * 1024)
      throw new Error("Native Files exports exceeded the bounded artifact size");
    const file = await open(source, constants.O_RDONLY | constants.O_NOFOLLOW);
    let bytes;
    try {
      const buffer = Buffer.alloc(information.size + 1);
      let offset = 0;
      while (offset < buffer.length) {
        const { bytesRead } = await file.read(buffer, offset, buffer.length - offset, null);
        if (!bytesRead) break;
        offset += bytesRead;
      }
      if (offset > information.size) throw new Error("Native Files export changed during bounded collection");
      bytes = buffer.subarray(0, offset);
    } finally {
      await file.close();
    }
    totalBytes += bytes.length;
    if (bytes.length > 16 * 1024 * 1024 || totalBytes > 64 * 1024 * 1024) throw new Error("Native Files exports exceeded the bounded artifact size");
    await writeFile(join(destination, entry.name), bytes);
    const record = { filename: entry.name, bytes: bytes.length, sha256: createHash("sha256").update(bytes).digest("hex") };
    manifest.push(record);
    await writeFile(join(destination, "manifest.json"), JSON.stringify(manifest, null, 2));
    if (sourcePDF) {
      if (bytes.subarray(0, 5).toString("ascii") !== "%PDF-") throw new Error("Native retained source export must contain PDF bytes");
      record.identity = "retained-source-pdf";
    } else if (pluginZIP) {
      if (!bytes.subarray(0, 4).equals(Buffer.from([0x50, 0x4b, 0x03, 0x04])))
        throw new Error("Native KOReader plugin export must contain ZIP bytes");
      record.identity = "koreader-plugin-zip";
      record.fixtureCredentialsIncluded = true;
    } else {
      const value = JSON.parse(bytes.toString("utf8"));
      record.identity = value.id ?? value.format ?? null;
    }
    await writeFile(join(destination, "manifest.json"), JSON.stringify(manifest, null, 2));
  }
  await writeFile(join(destination, "manifest.json"), JSON.stringify(manifest, null, 2));
  if (requireRecovery && !manifest.some((record) => /^RecoveryUI-/.test(record.filename)))
    throw new Error("Passing recovery journey must save its actual JSON export in public Documents");
  if (requirePlugin && !manifest.some((record) => record.identity === "koreader-plugin-zip"))
    throw new Error("Passing KOReader setup journey must save its actual plugin ZIP in public Documents");
  console.log(
    `[ipad.ui_exports] [end] runId=${runID} durationMs=${Date.now() - collectionStartedAt} files=${manifest.length} bytes=${totalBytes} - public Files exports collected`,
  );
}

async function captureEmailNativeEvidence(artifacts, phase) {
  const login = await fetch(`${env.IPAD_E04_API_URL}/auth/login`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ username: "ipad-owner", password: "IpadFixture123", clientKind: "native", deviceLabel: "E04 email artifact inspection" }),
    signal: AbortSignal.timeout(30_000),
  });
  if (!login.ok) throw new Error("Native email artifact inspection requires fixture authentication");
  const { accessToken, refreshToken } = await login.json();
  async function boundedArtifact(response, filename, maximum) {
    if (!response.ok) throw new Error(`Native email artifact request failed: ${response.status}`);
    const chunks = [];
    let size = 0;
    for await (const chunk of response.body) {
      size += chunk.length;
      if (size > maximum) throw new Error("Native email evidence exceeded its bounded artifact size");
      chunks.push(chunk);
    }
    const bytes = Buffer.concat(chunks);
    await writeFile(join(artifacts, filename), bytes);
    return { filename, bytes: size, sha256: createHash("sha256").update(bytes).digest("hex") };
  }
  const source = await boundedArtifact(
    await fetch(`${env.IPAD_E04_API_URL}/books/files/1/serve`, {
      headers: { authorization: `Bearer ${accessToken}` },
      signal: AbortSignal.timeout(30_000),
    }),
    `email-native-source-${phase}.pdf`,
    20 * 1024 * 1024,
  );
  const records = { phase, capturedAt: new Date().toISOString(), fileId: 1, source };
  if (phase === "after") {
    records.receivedMessages = await boundedArtifact(
      await fetch(`${env.IPAD_E04_SMTP_HTTP_URL}/messages`, { signal: AbortSignal.timeout(30_000) }),
      "email-native-received-messages.json",
      32 * 1024 * 1024,
    );
    const before = JSON.parse(await readFile(join(artifacts, "email-native-evidence-before.json"), "utf8"));
    records.sourceUnchangedDuringJourney = before.source.sha256 === source.sha256;
    if (!records.sourceUnchangedDuringJourney) throw new Error("Source PDF changed during the exclusive native email evidence lane");
  }
  await writeFile(join(artifacts, `email-native-evidence-${phase}.json`), `${JSON.stringify(records, null, 2)}\n`);
  const logout = await fetch(`${env.IPAD_E04_API_URL}/auth/logout`, {
    method: "POST",
    headers: { authorization: `Bearer ${accessToken}`, "content-type": "application/json" },
    body: JSON.stringify({ refreshToken }),
    signal: AbortSignal.timeout(30_000),
  });
  if (!logout.ok) throw new Error("Native email artifact inspection logout failed");
}

const children = new Set();
const stops = new WeakMap();
let interrupted = false;
let resolveInterrupt;
const interrupt = new Promise((resolve) => {
  resolveInterrupt = resolve;
});
function launch(cmd, args, options = {}) {
  if (interrupted) throw new Error("iPad harness interrupted");
  const child = spawn(cmd, args, { cwd: root, env, detached: true, ...options });
  children.add(child);
  return child;
}
function signalGroup(child, signal) {
  if (!child.pid) return;
  try {
    process.kill(-child.pid, signal);
  } catch (error) {
    if (error.code !== "ESRCH") throw error;
  }
}
function requestStop() {
  interrupted = true;
  resolveInterrupt();
  for (const child of children) {
    if (e03Proof && (child === server || child === migrationFixtureHolder)) continue;
    void stop(child);
  }
}
process.once("SIGINT", requestStop);
process.once("SIGTERM", requestStop);

let server;
let web;
let stopFaultProxy;
let externalReceivers;
let readingSharingVisuals = [];
let readingSharingHTTP;
let readingSharingBrowser;
let restartMonitor;
let restartMonitoringStopped = false;
let restartFailure;
async function runReadingSharingHTTP() {
  const output = await command(process.execPath, ["--test", "--test-reporter=tap", "--test-concurrency=1", ...readingSharing.httpFiles], {
    capture: true,
  });
  const count = (name) => Number(output.match(new RegExp(`^# ${name} (\\d+)$`, "m"))?.[1]);
  readingSharingHTTP = {
    tests: count("tests"),
    passed: count("pass"),
    failed: count("fail"),
    skipped: count("skipped"),
    cancelled: count("cancelled"),
    files: readingSharing.httpFiles,
  };
  await writeFile(`${artifactsRoot}/http-summary.json`, `${JSON.stringify(readingSharingHTTP, null, 2)}\n`);
  if (
    !(readingSharingHTTP.tests > 0) ||
    readingSharingHTTP.tests !== readingSharingHTTP.passed ||
    readingSharingHTTP.failed !== 0 ||
    readingSharingHTTP.skipped !== 0 ||
    readingSharingHTTP.cancelled !== 0
  )
    throw new Error("E04 HTTP coverage requires executed passing tests with no skips or cancellations");
}
async function startCore({ restart = false } = {}) {
  const fixture = restart ? JSON.parse(await readFile(join(artifactsRoot, "e04-fixture.json"), "utf8")) : undefined;
  const args = [
    ...(readingSharingProof ? ["--import", join(root, "scripts/ipad/kobo-query-observer.mjs")] : []),
    ...(e03Proof ? ["--import", join(root, "scripts/ipad/e03-request-metadata-preload.mjs")] : []),
    join(root, "server/dist-ipad/test/ipad/harness.js"),
  ];
  server = launch(process.execPath, args, {
    cwd: join(root, "server"),
    env: { ...env, IPAD_E04_RESTART: restart ? "1" : "0", ...(restart ? { IPAD_HARNESS_CONTENT_DIR: fixture.contentDirectory } : {}) },
    stdio: ["ignore", "pipe", "inherit"],
  });
  server.stdout.pipe(createWriteStream(`${artifactsRoot}/server.log`, { flags: restart ? "a" : "w" }));
  await new Promise((resolve, reject) => {
    let tail = "";
    const timeout = setTimeout(() => reject(new Error("iPad harness did not start within 120 seconds")), 120_000);
    server.once("error", reject);
    server.once("exit", (code) => {
      clearTimeout(timeout);
      reject(new Error(`iPad harness exited (${code})`));
    });
    server.stdout.on("data", (chunk) => {
      process.stdout.write(chunk);
      tail = (tail + chunk.toString()).slice(-1024);
      if (tail.includes("localhost server ready")) {
        clearTimeout(timeout);
        resolve();
      }
    });
  });
}

async function retainE04Core() {
  await mkdir(env.IPAD_E04_RESTART_DIRECTORY, { recursive: true });
  let completed;
  while (!interrupted && !restartMonitoringStopped) {
    let request;
    try {
      const bytes = await readFile(join(env.IPAD_E04_RESTART_DIRECTORY, "request.json"));
      if (bytes.length > 256) throw new Error("Core restart request exceeded its bounded size");
      request = JSON.parse(bytes.toString("utf8"));
      if (!/^[a-f0-9-]{36}$/i.test(request.requestId)) throw new Error("Core restart request must have a UUID identity");
    } catch (error) {
      if (error.code !== "ENOENT") throw error;
    }
    if (request && request.requestId !== completed) {
      const restartingAt = Date.now();
      console.log(`[ipad.core_restart] [start] runId=${runID} - restarting the retained core with its existing database and fixture`);
      await stop(server, "SIGUSR2");
      await startCore({ restart: true });
      completed = request.requestId;
      const temporary = join(env.IPAD_E04_RESTART_DIRECTORY, "ready.tmp");
      await writeFile(temporary, `${JSON.stringify({ requestId: completed, ready: true })}\n`);
      await rename(temporary, join(env.IPAD_E04_RESTART_DIRECTORY, "ready.json"));
      console.log(`[ipad.core_restart] [end] runId=${runID} durationMs=${Date.now() - restartingAt} ready=true - retained core restarted`);
    }
    await Promise.race([interrupt, new Promise((resolve) => setTimeout(resolve, 120))]);
  }
}
let requestFixture;
let responseProxy;
let migrationFixtureHolder;
let migrationFixtureReady = false;
async function prepareE03MigrationFixtures() {
  env.IPAD_MIGRATION_ARTIFACTS_ROOT = join(artifactsRoot, "migration-native");
  migrationFixtureHolder = launch(
    process.execPath,
    ["scripts/ipad/e03-migration-retain.mjs", ...(!process.argv.includes("--ui") ? ["--apply"] : [])],
    { stdio: "inherit" },
  );
  let startupError;
  migrationFixtureHolder.once("error", (error) => {
    startupError = error;
  });
  const deadline = Date.now() + 30 * 60_000;
  const checkpointPath = join(env.IPAD_MIGRATION_ARTIFACTS_ROOT, "fixture-checkpoint.json");
  while (Date.now() < deadline) {
    if (interrupted) throw new Error("iPad harness interrupted during migration preparation");
    if (startupError) throw startupError;
    if (migrationFixtureHolder.exitCode !== null || migrationFixtureHolder.signalCode !== null)
      throw new Error("Retained migration fixture holder exited before readiness");
    try {
      const checkpoint = JSON.parse(await readFile(checkpointPath, "utf8"));
      if (checkpoint.status === "ready") {
        const config = await readFile(join(env.IPAD_MIGRATION_ARTIFACTS_ROOT, "native-config.json"), "utf8");
        env.IPAD_MIGRATION_NATIVE_CONFIG = config;
        env.TEST_RUNNER_IPAD_MIGRATION_NATIVE_CONFIG = config;
        migrationFixtureReady = true;
        return;
      }
    } catch (error) {
      if (error.code !== "ENOENT") throw error;
    }
    await new Promise((resolve) => setTimeout(resolve, 1_000));
  }
  throw new Error("Retained migration fixture preparation exceeded 30 minutes");
}
async function configureE03Fixtures() {
  const fixture = JSON.parse(await readFile(env.IPAD_E03_FIXTURE_FILE, "utf8"));
  const client = new Client({ connectionString: databaseURL });
  await client.connect();
  let merge;
  try {
    merge = await seedDuplicateMergeFixture(client, join(fixture.contentRoot, "e03-http-merge"), fixture.libraryFolderId);
    fixture.maintenance = {
      ...fixture.maintenance,
      ...(await seedDuplicateMergeFixture(client, join(fixture.contentRoot, "e03-native-merge"), fixture.libraryFolderId)),
    };
  } finally {
    await client.end();
  }
  await writeFile(`${artifactsRoot}/e03-merge-fixture.json`, `${JSON.stringify(merge, null, 2)}\n`);
  fixture.maintenanceHttp = { ...fixture.maintenanceHttp, ...merge };
  await writeFile(env.IPAD_E03_FIXTURE_FILE, `${JSON.stringify(fixture, null, 2)}\n`);
  requestFixture = await startRequestAdminFixture({ port: 0, localDownloadPath: fixture.downloadRoot });
  const { PDFDocument } = require("pdf-lib");
  const largePDF = await PDFDocument.load(await readFile(fixture.uploadFile));
  largePDF.setCreationDate(new Date("2026-10-05T00:00:00Z"));
  largePDF.setModificationDate(new Date("2026-10-05T00:00:00Z"));
  const payload = new Uint8Array(12 * 1024 * 1024);
  let seed = 0x1e03;
  for (let index = 0; index < payload.length; index++) {
    seed ^= seed << 13;
    seed ^= seed >>> 17;
    seed ^= seed << 5;
    payload[index] = seed & 0xff;
  }
  await largePDF.attach(payload, "E03 deterministic payload.bin", { mimeType: "application/octet-stream" });
  fixture.largeUploadFile = join(fixture.contentRoot, "E03 upload large.pdf");
  await writeFile(fixture.largeUploadFile, await largePDF.save());
  const largeUploadSHA256 = createHash("sha256")
    .update(await readFile(fixture.largeUploadFile))
    .digest("hex");
  fixture.dockPath = join(fixture.contentRoot, "data", "book-dock");
  await writeFile(env.IPAD_E03_FIXTURE_FILE, `${JSON.stringify(fixture, null, 2)}\n`);
  responseProxy = await startE03ResponseProxy({
    seedDock: async () => {
      await mkdir(fixture.dockPath, { recursive: true });
      const filename = `E03 scanned source ${randomBytes(8).toString("hex")}.pdf`;
      const target = join(fixture.dockPath, filename);
      await copyFile(fixture.uploadFile, target);
      return {
        filename,
        sha256: createHash("sha256")
          .update(await readFile(target))
          .digest("hex"),
      };
    },
  });
  Object.assign(env, {
    IPAD_MERGE_FIXTURE: `${artifactsRoot}/e03-merge-fixture.json`,
    IPAD_MAINTENANCE_FIXTURE: JSON.stringify(fixture.maintenanceHttp),
    IPAD_E03_SCAN_LIBRARY_ID: String(fixture.scanLibraryId),
    IPAD_E03_SCAN_PATH: fixture.scanPath,
    IPAD_E03_DOWNLOAD_PATH: dirname(requestFixture.filePath),
    IPAD_E03_PROTOCOL_URL: requestFixture.origin,
    IPAD_E03_FAULT_URL: responseProxy.origin,
    IPAD_E03_SERVER_URL: responseProxy.origin,
    IPAD_MIGRATION_IMPORT_ROOT: env.MIGRATION_IMPORT_ROOT,
    IPAD_MIGRATION_BOOKS_ROOT: fixture.contentRoot,
    IPAD_E03_UPLOAD_FILE: fixture.uploadFile,
    IPAD_E03_LARGE_UPLOAD_FILE: fixture.largeUploadFile,
    IPAD_E03_LARGE_UPLOAD_SHA256: largeUploadSHA256,
    IPAD_E03_DOCK_PATH: fixture.dockPath,
    IPAD_MAINTENANCE_REPLACEMENT_PATH: fixture.maintenance.replacementPath,
    IPAD_MAINTENANCE_MISSING_BOOK_ID: String(fixture.maintenance.missingBookId),
    IPAD_MAINTENANCE_SOURCE_BOOK_ID: String(fixture.maintenance.sourceBookId),
    IPAD_MAINTENANCE_TARGET_BOOK_ID: String(fixture.maintenance.targetBookId),
    TEST_RUNNER_IPAD_E03_UPLOAD_FILE: fixture.uploadFile,
    TEST_RUNNER_IPAD_E03_LARGE_UPLOAD_FILE: fixture.largeUploadFile,
    TEST_RUNNER_IPAD_E03_LARGE_UPLOAD_SHA256: largeUploadSHA256,
    TEST_RUNNER_IPAD_E03_DOCK_PATH: fixture.dockPath,
    TEST_RUNNER_IPAD_E03_SCAN_LIBRARY_ID: String(fixture.scanLibraryId),
    TEST_RUNNER_IPAD_E03_PROTOCOL_URL: requestFixture.origin,
    TEST_RUNNER_IPAD_E03_FAULT_URL: responseProxy.origin,
    TEST_RUNNER_IPAD_E03_SERVER_URL: responseProxy.origin,
    TEST_RUNNER_IPAD_MAINTENANCE_FIXTURE: JSON.stringify(fixture.maintenance),
    TEST_RUNNER_IPAD_MAINTENANCE_REPLACEMENT_PATH: fixture.maintenance.replacementPath,
    TEST_RUNNER_IPAD_MAINTENANCE_MISSING_BOOK_ID: String(fixture.maintenance.missingBookId),
    TEST_RUNNER_IPAD_MAINTENANCE_SOURCE_BOOK_ID: String(fixture.maintenance.sourceBookId),
    TEST_RUNNER_IPAD_MAINTENANCE_TARGET_BOOK_ID: String(fixture.maintenance.targetBookId),
    ...(env.IPAD_MIGRATION_NATIVE_CONFIG ? { TEST_RUNNER_IPAD_MIGRATION_NATIVE_CONFIG: env.IPAD_MIGRATION_NATIVE_CONFIG } : {}),
  });
  const keys = [
    "DATABASE_URL",
    "E2E_DATABASE_URL",
    "IPAD_TEST_RUN",
    "IPAD_TEST_ARTIFACTS",
    "IPAD_FIXTURE_PASSWORD",
    "IPAD_E03_PROOF",
    "IPAD_E03_API_URL",
    "IPAD_E03_BASE_URL",
    "IPAD_API_BASE",
    "IPAD_E03_FIXTURE_FILE",
    "IPAD_E03_UPLOAD_RECEIPT_FILE",
    "IPAD_E03_RECOVERY_RUN_ID",
    "IPAD_MERGE_FIXTURE",
    "IPAD_MAINTENANCE_FIXTURE",
    "IPAD_MAINTENANCE_REPLACEMENT_PATH",
    "IPAD_MAINTENANCE_MISSING_BOOK_ID",
    "IPAD_MAINTENANCE_SOURCE_BOOK_ID",
    "IPAD_MAINTENANCE_TARGET_BOOK_ID",
    "IPAD_E03_SCAN_LIBRARY_ID",
    "IPAD_E03_SCAN_PATH",
    "IPAD_E03_DOWNLOAD_PATH",
    "IPAD_E03_PROTOCOL_URL",
    "IPAD_E03_FAULT_URL",
    "IPAD_E03_SERVER_URL",
    "IPAD_MIGRATION_IMPORT_ROOT",
    "IPAD_MIGRATION_BOOKS_ROOT",
    "IPAD_MIGRATION_NATIVE_CONFIG",
    "IPAD_E03_UPLOAD_FILE",
    "IPAD_E03_LARGE_UPLOAD_FILE",
    "IPAD_E03_LARGE_UPLOAD_SHA256",
    "IPAD_E03_DOCK_PATH",
    "MIGRATION_IMPORT_ROOT",
    "BOOK_REQUEST_ENCRYPTION_KEY",
    ...Object.keys(env).filter((key) => /^TEST_RUNNER_IPAD_(?:E03_|MAINTENANCE_|MIGRATION_)/.test(key)),
  ];
  const shellQuote = (value) => `'${String(value).replaceAll("'", "'\\''")}'`;
  const auth = await fetch(`${env.IPAD_E03_API_URL}/auth/login`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      username: "ipad-owner",
      password: env.IPAD_FIXTURE_PASSWORD,
      clientKind: "native",
      deviceLabel: "E03 fixture preparation",
    }),
  });
  if (!auth.ok) throw new Error("E03 fixture preparation requires owner authentication");
  const session = await auth.json();
  try {
    for (const [path, body] of [
      [
        "admin/request-indexers",
        {
          name: "E03 controlled source",
          adapterType: "torznab",
          baseUrl: `${requestFixture.origin}/torznab/api`,
          allowPrivateAddress: true,
          enabled: true,
        },
      ],
      [
        "admin/download-clients",
        {
          name: "E03 controlled client",
          adapterType: "qbittorrent",
          baseUrl: requestFixture.origin,
          allowPrivateAddress: true,
          enabled: true,
          category: "bookorbit",
          useHardlinks: false,
          pathMappings: [{ remotePath: dirname(requestFixture.filePath), localPath: dirname(requestFixture.filePath) }],
        },
      ],
    ]) {
      const result = await fetch(`${env.IPAD_E03_API_URL}/${path}`, {
        method: "POST",
        headers: { Authorization: `Bearer ${session.accessToken}`, "content-type": "application/json" },
        body: JSON.stringify(body),
      });
      if (!result.ok) throw new Error(`E03 protocol configuration failed (${result.status}): ${await result.text()}`);
    }
    for (const [bookID, author] of [
      [1, "Entity fixture author"],
      [2, "Entity fixture target"],
    ]) {
      const result = await fetch(`${env.IPAD_E03_API_URL}/books/${bookID}/metadata`, {
        method: "PATCH",
        headers: { Authorization: `Bearer ${session.accessToken}`, "content-type": "application/json" },
        body: JSON.stringify({
          title: bookID === 1 ? "A E03 PDF fixture" : "A E03 EPUB fixture",
          authors: [author],
          tags: ["Entity fixture tag"],
          genres: ["Entity fixture genre"],
          publisher: "Entity fixture publisher",
        }),
      });
      if (!result.ok) throw new Error(`E03 entity fixture preparation failed (${result.status})`);
    }
  } finally {
    await fetch(`${env.IPAD_E03_API_URL}/auth/logout`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ refreshToken: session.refreshToken }),
    });
  }
  await writeFile(`${artifactsRoot}/runtime-request-encryption-key`, `${env.BOOK_REQUEST_ENCRYPTION_KEY}\n`, { mode: 0o600 });
  await writeFile(`${artifactsRoot}/runtime-jwt-secret`, `${env.JWT_SECRET}\n`, { mode: 0o600 });
  await writeFile(`${artifactsRoot}/e03-runtime.env`, keys.map((key) => `export ${key}=${shellQuote(env[key] ?? "")}`).join("\n") + "\n", {
    mode: 0o600,
  });
}
async function startWeb() {
  if (web) return;
  web = launch(packageManager, ["--filter", "client", "exec", "vite", "preview", "--host", "127.0.0.1", "--port", String(webPort), "--strictPort"], {
    env: { ...env, BOOKORBIT_API_TARGET: `http://localhost:${apiPort}` },
    stdio: "inherit",
  });
  const deadline = Date.now() + 30_000;
  while (true) {
    if (web.exitCode !== null) throw new Error("iPad web server exited before becoming ready");
    try {
      if ((await fetch(`http://localhost:${webPort}`, { signal: AbortSignal.timeout(1000) })).ok) break;
    } catch {}
    if (Date.now() >= deadline) throw new Error("iPad web server did not become ready");
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
}

async function runAdditionalAnnotationBrowserTests() {
  if (!annotationsProof || qa5BrowserOnly) return;
  const suites = [
    { config: "scripts/ipad/annotations-collection.config.mjs", cases: ["A01", "A03"], artifactSuffix: "collection" },
    { config: "scripts/ipad/source-ink-window-web.config.mjs", cases: ["A03"], artifactSuffix: "source-window" },
  ];
  for (const suite of suites) {
    if (annotationCase && !suite.cases.includes(annotationCase)) continue;
    await command(
      packageManager,
      ["exec", "playwright", "test", "--config", suite.config, ...(annotationCase ? ["--grep", `IPAD-E02-${annotationCase}`] : [])],
      {
        env: { ...env, IPAD_TEST_RUN: `${runID}-${suite.artifactSuffix}` },
      },
    );
  }
}
async function stop(child, signal = "SIGTERM") {
  if (!child || child.exitCode !== null || child.signalCode !== null) return;
  if (stops.has(child)) return stops.get(child);
  const stopped = new Promise((resolve, reject) => {
    const timeout = setTimeout(() => {
      try {
        signalGroup(child, "SIGKILL");
      } catch (error) {
        reject(error);
      }
    }, 10_000);
    child.once("exit", () => {
      clearTimeout(timeout);
      children.delete(child);
      resolve();
    });
    try {
      signalGroup(child, signal);
    } catch (error) {
      clearTimeout(timeout);
      reject(error);
    }
  });
  stops.set(child, stopped);
  return stopped;
}
async function cleanup() {
  restartMonitoringStopped = true;
  const fixtureFailures = [];
  try {
    await stop(migrationFixtureHolder);
    if (migrationFixtureReady)
      await execute(process.execPath, ["scripts/ipad/e03-migration-retain.mjs", "--cleanup"], { cwd: root, env, timeout: 120_000 });
  } catch (error) {
    fixtureFailures.push({ status: "rejected", reason: error });
  }
  await requestFixture?.close();
  await responseProxy?.close();
  await stopFaultProxy?.();
  await externalReceivers?.close();
  const stopped = await Promise.allSettled([...children].map((child) => stop(child)));
  if (e03Proof) await stopRecoveredRuntime();
  await restartMonitor;
  if (!existingServer) {
    const client = new Client({ connectionString: "postgres://bookorbit:bookorbit@localhost:5432/postgres" });
    await client.connect();
    try {
      await client.query(`DROP DATABASE IF EXISTS "${databaseName}" WITH (FORCE)`);
    } finally {
      await client.end();
    }
  }
  const failures = [...fixtureFailures, ...stopped.filter((result) => result.status === "rejected")];
  if (failures.length)
    throw new AggregateError(
      failures.map((result) => result.reason),
      "iPad subprocess cleanup failed",
    );
}

async function stopRecoveredRuntime() {
  let runtime;
  try {
    runtime = JSON.parse(await readFile(join(artifactsRoot, "restarted-runtime.json"), "utf8"));
  } catch (error) {
    if (error.code === "ENOENT") return;
    throw error;
  }
  if (runtime.runID !== runID) throw new Error("Recovered runtime does not belong to this isolated fixture");
  for (const [pid, commandPath] of [
    [runtime.supervisorPID, "scripts/ipad/restart-server.mjs"],
    [runtime.pid, "server/dist-ipad/test/ipad/harness.js"],
  ]) {
    if (!Number.isSafeInteger(pid) || pid <= 0) throw new Error("Recovered runtime PID is invalid");
    let commandLine;
    try {
      ({ stdout: commandLine } = await execute("ps", ["-p", String(pid), "-o", "command="], { maxBuffer: 4096 }));
    } catch (error) {
      if (error.code === 1 && !error.stdout?.trim()) continue;
      throw error;
    }
    if (!commandLine.includes(commandPath) || (commandPath.endsWith("restart-server.mjs") && !commandLine.includes(runID))) {
      throw new Error("Recovered runtime PID was reused; no process was stopped");
    }
    try {
      process.kill(pid, "SIGTERM");
    } catch (error) {
      if (error.code !== "ESRCH") throw error;
    }
  }
}

async function runNativeTests({ onExecutionStart, onFailure } = {}) {
  const startedAt = Date.now();
  let nativeCommandDeadline = combinedRecovery ? Date.now() + combinedNativePreparationBudgetMs : undefined;
  async function nativeCommand(cmd, args, options = {}) {
    if (!nativeCommandDeadline) return command(cmd, args, options);
    const remaining = nativeCommandDeadline - Date.now();
    if (remaining <= 0) throw new Error("QA456 native phase exceeded its owning deadline");
    return command(cmd, args, { ...options, timeoutMs: Math.min(options.timeoutMs ?? remaining, remaining) });
  }
  const nativeLock = readingSharingProof ? "/tmp/bookorbit-ipad-e04-xcode.lock" : "/tmp/bookorbit-ipad-xcode.lock";
  try {
    await mkdir(nativeLock);
  } catch (error) {
    if (error.code === "EEXIST")
      throw new Error(`Native runner already owned: ${await readFile(`${nativeLock}/owner.json`, "utf8").catch(() => "owner starting")}`);
    throw error;
  }
  await writeFile(`${nativeLock}/owner.json`, JSON.stringify({ pid: process.pid, runID, root }));
  console.log(`[ipad.ui] [start] runId=${runID} filtered=${Boolean(process.env.IPAD_TEST_ONLY)} - native verification starting`);
  try {
    const artifacts = artifactsRoot;
    await mkdir(artifacts, { recursive: true });
    const devices = JSON.parse(await nativeCommand("xcrun", ["simctl", "list", "devices", "available", "--json"], { capture: true }));
    const explicitID = process.env.IPAD_TEST_DESTINATION?.match(/(?:^|,)id=([A-Fa-f0-9-]+)/)?.[1];
    const explicitName = process.env.IPAD_TEST_DESTINATION?.match(/(?:^|,)name=([^,]+)/)?.[1] ?? defaultNativeName;
    const matches = Object.values(devices.devices)
      .flat()
      .filter((device) => (explicitID ? device.udid === explicitID : device.name === explicitName));
    if (matches.length !== 1) throw new Error("Select exactly one available test simulator with IPAD_TEST_DESTINATION");
    const selectedDevice = matches[0];
    const prepared = preparedNativeBuild ? await validatePreparedNativeBuild(selectedDevice.udid) : undefined;
    currentNativeDeviceID = selectedDevice.udid;
    if (selectedDevice.state === "Shutdown") await nativeCommand("xcrun", ["simctl", "boot", selectedDevice.udid]);
    await nativeCommand("xcrun", ["simctl", "bootstatus", selectedDevice.udid, "-b"]);
    if (annotationsProof || readingSharingProof || e03Proof) {
      const size = nativeVisualProfile.nativeDevice.includes("11") ? "11-inch" : "13-inch";
      if (!selectedDevice.deviceTypeIdentifier?.includes(size)) throw new Error(`Native profile requires an actual ${size} iPad simulator`);
      const contentSize =
        nativeVisualProfile.dynamicType === "accessibilityExtraExtraExtraLarge"
          ? "accessibility-extra-extra-extra-large"
          : nativeVisualProfile.dynamicType === "extraExtraExtraLarge"
            ? "extra-extra-extra-large"
            : "large";
      await nativeCommand("xcrun", ["simctl", "ui", selectedDevice.udid, "appearance", nativeVisualProfile.colorScheme]);
      await nativeCommand("xcrun", ["simctl", "ui", selectedDevice.udid, "content_size", contentSize]);
      const appearance = (await nativeCommand("xcrun", ["simctl", "ui", selectedDevice.udid, "appearance"], { capture: true })).trim();
      const actualContentSize = (await nativeCommand("xcrun", ["simctl", "ui", selectedDevice.udid, "content_size"], { capture: true })).trim();
      if (appearance !== nativeVisualProfile.colorScheme || actualContentSize !== contentSize)
        throw new Error("Actual simulator appearance or content size differs from the requested profile");
      await writeFile(
        `${artifacts}/native-profile.json`,
        JSON.stringify(
          {
            requestedProfile: annotationVisualProfile.name,
            appliedProfile: nativeVisualProfile.name,
            deviceID: selectedDevice.udid,
            appearance,
            contentSize: actualContentSize,
            reduceMotion: { expected: nativeVisualProfile.reducedMotion === "reduce", verified: false },
            nativeWindow: "full",
            narrowWindowCoverage:
              annotationVisualProfile.window === "narrow"
                ? "residual: simctl has no window sizing command; native full-window counterpart is run"
                : "not-requested",
          },
          null,
          2,
        ),
      );
      if (prepared) {
        const record = JSON.parse(await readFile(`${artifacts}/native-profile.json`, "utf8"));
        record.reduceMotion.verified = true;
        record.profileEvidence = prepared.profileEvidence;
        record.preparedBuildSource = prepared.source;
        await writeFile(`${artifacts}/native-profile.json`, JSON.stringify(record, null, 2));
        await copyFile(join(prepared.source, "profile-summary.json"), `${artifacts}/profile-summary.json`);
        await writeFile(`${artifacts}/native-build-provenance.json`, JSON.stringify(prepared, null, 2));
      }
    }
    if (!readerProof && !annotationsProof && !readingSharingProof) {
      const destination = process.env.IPAD_TEST_DESTINATION;
      const device = destination?.match(/(?:^|,)id=([A-Fa-f0-9-]+)/)?.[1] ?? "BookOrbit Test iPad";
      await nativeCommand("xcrun", [
        "simctl",
        "addmedia",
        device,
        `${env.IPAD_COVER_FIXTURE_DIR}/ebook-selected.png`,
        `${env.IPAD_COVER_FIXTURE_DIR}/ebook-large-selected.png`,
      ]);
    }
    if (annotationsProof || readingSharingProof) {
      const device = selectedDevice.udid;
      let installed = false;
      try {
        await nativeCommand("xcrun", ["simctl", "get_app_container", device, "com.mooneeb.bookorbit.private", "data"], { capture: true });
        installed = true;
      } catch {}
      if (installed && !isolatedNative && !prepared) await nativeCommand("xcrun", ["simctl", "uninstall", device, "com.mooneeb.bookorbit.private"]);
      await nativeCommand("xcrun", [
        "simctl",
        "status_bar",
        device,
        "override",
        "--time",
        "9:41",
        "--dataNetwork",
        "wifi",
        "--wifiMode",
        "active",
        "--wifiBars",
        "3",
        "--batteryState",
        "charged",
        "--batteryLevel",
        "100",
      ]);
    }
    if (!prepared || incrementalNativeBuild) await nativeCommand("xcodegen", ["generate", "--spec", "ipad/project.yml"]);
    if (e03Proof && !process.env.IPAD_TEST_ONLY) {
      nativeTests = [];
      for (const file of await readdir(`${root}/ipad/UITests`)) {
        if (!file.endsWith(".swift")) continue;
        const source = await readFile(`${root}/ipad/UITests/${file}`, "utf8");
        const className = source.match(/class\s+([A-Za-z_][A-Za-z_0-9]*)\s*:\s*XCTestCase/)?.[1];
        if (!className) continue;
        for (const match of source.matchAll(/func (testIPADE03[A-Za-z_0-9]*)\(/g)) {
          const methodCase = match[1].match(/A0[1-5]/)?.[0];
          const classCase = /Acquisition|Scan/.test(className)
            ? "A01"
            : /Request/.test(className)
              ? "A02"
              : /Migration/.test(className)
                ? "A03"
                : /Bulk/.test(className)
                  ? "A04"
                  : /Entit|Maintenance/.test(className)
                    ? "A05"
                    : undefined;
          if (!e03Case || (methodCase ?? classCase) === e03Case || className === "LibraryManagementJourneyTests")
            nativeTests.push(`BookOrbitUITests/${className}/${match[1]}`);
        }
      }
      if (!nativeTests.length) throw new Error(`No implemented native E03 ${e03Case ?? "all"} journey exists`);
    }
    if (annotationsProof && !isolatedNative && !process.env.IPAD_TEST_ONLY) {
      nativeTests = [];
      for (const file of await readdir(`${root}/ipad/UITests`)) {
        if (!file.endsWith(".swift")) continue;
        const source = await readFile(`${root}/ipad/UITests/${file}`, "utf8");
        const className = source.match(/class\s+([A-Za-z_][A-Za-z_0-9]*)\s*:\s*XCTestCase/)?.[1];
        if (!className) continue;
        const prefix = annotationCase === "A01" ? "(?:A01|P2)" : (annotationCase ?? "(?:A0[1-7]|P2)");
        for (const match of source.matchAll(new RegExp(`func (testIPADE02${prefix}[A-Za-z_0-9]*)\\(`, "g"))) {
          nativeTests.push(`BookOrbitUITests/${className}/${match[1]}`);
        }
      }
      if (!nativeTests.length) throw new Error(`No implemented native ${annotationCase ?? "E02"} journey exists`);
    }
    let nativeFailure;
    let exportedArtifactDirectory;
    let nativeJourneyStarted = false;
    let emailEvidenceStarted = false;
    const nativeEnvironment = {
      ...env,
      ...Object.fromEntries(
        Object.entries(env)
          .filter(([key]) => key.startsWith("IPAD_E04_"))
          .map(([key, value]) => [`TEST_RUNNER_${key}`, value]),
      ),
      TEST_RUNNER_IPAD_E04: env.IPAD_E04,
      IPAD_E04_PROFILE: nativeVisualProfile.name,
      TEST_RUNNER_IPAD_E04_PROFILE: nativeVisualProfile.name,
      IPAD_E02_PROFILE: nativeVisualProfile.name,
      TEST_RUNNER_IPAD_E02_CRITICAL_ONLY: env.IPAD_E02_CRITICAL_ONLY ?? "0",
    };
    try {
      const commonArguments = [
        "-project",
        "ipad/BookOrbit.xcodeproj",
        "-scheme",
        nativeScheme,
        ...(annotationsProof || readingSharingProof
          ? [
              "-testPlan",
              readingSharingProof ? "ReadingSharingAcceptance" : "AnnotationAcceptance",
              "-only-test-configuration",
              nativeVisualProfile.name,
            ]
          : []),
        "-parallel-testing-enabled",
        "NO",
        ...(readingSharingProof ? ["-jobs", "2"] : []),
        "-collect-test-diagnostics",
        "never",
        "-destination",
        nativeDestination,
        "-derivedDataPath",
        readingSharingProof ? "ipad/DerivedDataE04" : "ipad/DerivedData",
        "CODE_SIGNING_ALLOWED=YES",
        "CODE_SIGN_IDENTITY=-",
      ];
      if (incrementalNativeBuild) {
        await nativeCommand("xcodebuild", ["build-for-testing", ...commonArguments, "-resultBundlePath", `${artifacts}/build.xcresult`], {
          env: nativeEnvironment,
        });
        prepared.binaries = await nativeBuildBinaries();
        prepared.compiledAt = new Date().toISOString();
        prepared.workingTreeEditsAfterProfileIncluded = true;
        prepared.buildEvidence = join(artifacts, "build.xcresult");
        await writeFile(`${artifacts}/native-build-provenance.json`, JSON.stringify(prepared, null, 2));
      }
      if ((annotationsProof || readingSharingProof) && !isolatedNative && !prepared) {
        const preflight = "BookOrbitUITests/AnnotationProfilePerformanceTests/testIPADE02A01ApplySystemProfile";
        await nativeCommand(
          "xcodebuild",
          ["test", ...commonArguments, "-resultBundlePath", `${artifacts}/profile.xcresult`, `-only-testing:${preflight}`],
          { env: nativeEnvironment },
        );
        const profileSummaryText = await nativeCommand(
          "xcrun",
          ["xcresulttool", "get", "test-results", "summary", "--path", `${artifacts}/profile.xcresult`, "--format", "json"],
          { capture: true },
        );
        await writeFile(`${artifacts}/profile-summary.json`, profileSummaryText);
        const profileSummary = JSON.parse(profileSummaryText);
        if (
          profileSummary.totalTestCount !== 1 ||
          profileSummary.passedTests !== 1 ||
          profileSummary.failedTests !== 0 ||
          profileSummary.skippedTests !== 0 ||
          profileSummary.expectedFailures !== 0
        )
          throw new Error("Native system profile requires its actual Settings/UI preflight to execute and pass without skips");
        const profileRecord = JSON.parse(await readFile(`${artifacts}/native-profile.json`, "utf8"));
        profileRecord.reduceMotion.verified = true;
        profileRecord.profileEvidence = "profile.xcresult";
        await writeFile(`${artifacts}/native-profile.json`, JSON.stringify(profileRecord, null, 2));
        nativeTests = nativeTests.filter((name) => name !== preflight);
        if (!nativeTests.length)
          throw new Error("Profile preflight completed; select an acceptance journey or performance method for native verification");
        if (annotationsProof) {
          exportedArtifactDirectory = await publicExportDirectory(selectedDevice.udid);
          nativeEnvironment.IPAD_E02_EXPORTED_ARTIFACT_DIRECTORY = exportedArtifactDirectory;
          nativeEnvironment.TEST_RUNNER_IPAD_E02_EXPORTED_ARTIFACT_DIRECTORY = exportedArtifactDirectory;
        }
        await nativeCommand("xcrun", [
          "xcresulttool",
          "export",
          "attachments",
          "--path",
          `${artifacts}/profile.xcresult`,
          "--output-path",
          `${artifacts}/profile-attachments`,
        ]);
      }
      if (isolatedNative || e03Proof) {
        if (!reuseNativeBuild) await nativeCommand("xcodebuild", ["build-for-testing", ...commonArguments], { env: nativeEnvironment });
        else if (!(await lstat(join(root, "ipad/DerivedData/Build/Products/Debug-iphonesimulator/BookOrbit.app/BookOrbit"))).isFile())
          throw new Error("Joined native app build is absent");
        await nativeCommand("xcrun", [
          "simctl",
          "install",
          selectedDevice.udid,
          "ipad/DerivedData/Build/Products/Debug-iphonesimulator/BookOrbit.app",
        ]);
        if (e03Proof) {
          const documents = await publicExportDirectory(selectedDevice.udid, { create: true });
          await copyFile(env.IPAD_E03_UPLOAD_FILE, join(documents, "E03 upload.pdf"));
          await copyFile(env.IPAD_E03_LARGE_UPLOAD_FILE, join(documents, "E03 upload large.pdf"));
        }
        if (combinedRecovery || pdfRecovery) {
          nativeEnvironment.IPAD_E02_CURRENT_PUBLIC_FILES = "1";
          nativeEnvironment.TEST_RUNNER_IPAD_E02_CURRENT_PUBLIC_FILES = "1";
        }
      }
      nativeJourneyStarted = true;
      const emailEvidence =
        readingSharingProof &&
        [
          "BookOrbitUITests/EmailDeliveryJourneyTests/testIPADE04A03NativeMailSettingsSelectedFileAndReceiver",
          "BookOrbitUITests/EmailDeliveryJourneyTests/testIPADE04A03NativeRetainedSelectedPDFDeliveryAndRetry",
          "BookOrbitUITests/EmailDeliveryJourneyTests/testIPADE04A03NativeSameRunSelectedPDFDeliveryAndRetry",
        ].some((name) => nativeTests.includes(name));
      if (emailEvidence) {
        await captureEmailNativeEvidence(artifacts, "before");
        emailEvidenceStarted = true;
      }
      if (combinedRecovery) {
        nativeCommandDeadline = Date.now() + combinedNativeExecutionBudgetMs;
        onExecutionStart?.(nativeCommandDeadline);
      }
      await nativeCommand(
        "xcodebuild",
        [
          annotationsProof || readingSharingProof || e03Proof ? "test-without-building" : "test",
          ...commonArguments,
          "-resultBundlePath",
          `${artifacts}/native.xcresult`,
          ...(nativeTests.length
            ? nativeTests.map((name) => `-only-testing:${name}`)
            : comicProof
              ? ["-only-testing:BookOrbitReaderProofUITests/ComicReaderProofTests"]
              : pdfReader
                ? ["-only-testing:BookOrbitUITests/EntryJourneyTests/testIPADE01A03ProductionPDFCurlAndResume"]
                : readerProof && !epubProof
                  ? ["-only-testing:BookOrbitReaderProofUITests/PDFReaderProofTests"]
                  : []),
        ],
        { env: nativeEnvironment },
      );
    } catch (error) {
      nativeFailure = error;
      onFailure?.(error);
    }
    if (emailEvidenceStarted && !interrupted) {
      try {
        await captureEmailNativeEvidence(artifacts, "after");
      } catch (error) {
        console.error(
          `[ipad.ui_email_evidence] [fail] runId=${runID} durationMs=${Date.now() - startedAt} errorClass=${error.name} error="${sanitizeLogValue(error.message)}" - native email evidence capture failed`,
        );
        nativeFailure ??= error;
      }
    }
    if (combinedRecovery) nativeCommandDeadline = Date.now() + combinedNativeEvidenceBudgetMs;
    if ((exportedArtifactDirectory || combinedRecovery || pdfRecovery || readingSharingProof) && nativeJourneyStarted) {
      try {
        if (combinedRecovery || pdfRecovery || readingSharingProof) exportedArtifactDirectory = await publicExportDirectory(selectedDevice.udid);
        const recoverySelected = nativeTests.some(
          (name) =>
            name === "BookOrbitUITests/RecoveryDraftJourneyTests" ||
            name === "BookOrbitUITests/RecoveryDraftJourneyTests/testIPADE02A06RecoveryDraftExportAndExplicitReattachmentPreserveDeletedOriginal",
        );
        const pluginSelected = nativeTests.includes("BookOrbitUITests/CatalogJourneyTests/testIPADE04A03KOReaderSetupAndMatching");
        await collectNativeFiles(
          exportedArtifactDirectory,
          artifacts,
          recoverySelected && !nativeFailure && !interrupted,
          pluginSelected && !nativeFailure && !interrupted,
        );
      } catch (error) {
        console.error(
          `[ipad.ui_exports] [fail] runId=${runID} durationMs=${Date.now() - startedAt} errorClass=${error.name} error="${sanitizeLogValue(error.message)}" - public Files artifact collection failed`,
        );
        nativeFailure ??= error;
      }
    }
    if (!interrupted) {
      try {
        const summaryText = await nativeCommand(
          "xcrun",
          ["xcresulttool", "get", "test-results", "summary", "--path", `${artifacts}/native.xcresult`, "--format", "json"],
          { capture: true },
        );
        await writeFile(`${artifacts}/native-summary.json`, summaryText);
        const exported = await nativeCommand(
          "xcrun",
          ["xcresulttool", "export", "attachments", "--path", `${artifacts}/native.xcresult`, "--output-path", `${artifacts}/native-attachments`],
          { capture: true },
        );
        await writeFile(`${artifacts}/native-attachments.log`, exported);
        if (annotationsProof && !isolatedNative) await compareNativeAnnotationVisuals(artifacts, nativeVisualProfile.name);
        if (readingSharingProof) readingSharingVisuals = await compareNativeReadingSharingVisuals(artifacts, nativeVisualProfile.name);
        const summary = JSON.parse(summaryText);
        if (
          summary.totalTestCount < 1 ||
          (readingSharingProof && nativeTests.every((name) => name.split("/").length === 3) && summary.totalTestCount !== nativeTests.length) ||
          (isolatedNative && summary.totalTestCount !== 1) ||
          summary.failedTests !== 0 ||
          summary.skippedTests !== 0 ||
          summary.expectedFailures !== 0 ||
          summary.passedTests !== summary.totalTestCount
        ) {
          throw new Error("Native verification requires executed, passing tests with no skips or expected failures");
        }
        console.log(
          `[ipad.ui] [end] runId=${runID} durationMs=${Date.now() - startedAt} tests=${summary.totalTestCount} - native tests passed; evidence exported`,
        );
        if (e03Proof) await compareNativeE03Visuals(artifacts, nativeVisualProfile.name);
      } catch (error) {
        nativeFailure ??= error;
      }
    }
    if (nativeFailure) throw nativeFailure;
    if (interrupted) throw new Error("Native verification interrupted");
  } catch (error) {
    onFailure?.(error);
    console.error(
      `[ipad.ui] [fail] runId=${runID} durationMs=${Date.now() - startedAt} errorClass=${error instanceof Error ? error.name : "Error"} error="${sanitizeLogValue(error instanceof Error ? error.message : String(error))}" - native verification failed`,
    );
    throw error;
  } finally {
    await rm(nativeLock, { recursive: true, force: true });
  }
}

async function runCombinedNativeAndBrowser() {
  let resolveExecutionStarted;
  const executionStarted = new Promise((resolve) => {
    resolveExecutionStarted = resolve;
  });
  const browserAbort = new AbortController();
  let nativeReady = false;
  const native = runNativeTests({
    onExecutionStart: resolveExecutionStarted,
    onFailure: (error) => browserAbort.abort(error),
  }).then(() => {
    if (!nativeReady) browserAbort.abort(new Error("Native peer exited before its offline readiness checkpoint"));
  });
  const browser = (async () => {
    const deadline = await Promise.race([
      executionStarted,
      native.then(() => {
        throw new Error("Native peer exited before its browser lifecycle started");
      }),
    ]);
    await waitForNativeOfflineReady({ faultURL: env.IPAD_ANNOTATION_FAULT_URL, deadline, signal: browserAbort.signal });
    nativeReady = true;
    const remaining = deadline - Date.now();
    if (remaining <= 0) throw new Error("QA456 browser has no time remaining in the owning native run");
    await command(packageManager, ["exec", "playwright", "test", "--config", "scripts/ipad/playwright.config.mjs"], {
      env: { ...env, IPAD_QA456_NATIVE_DEADLINE_MS: String(deadline) },
      timeoutMs: remaining,
      signal: browserAbort.signal,
    });
  })();
  return Promise.allSettled([native, browser]);
}

try {
  console.log(`[ipad.harness] [start] runId=${runID} annotations=${annotationsProof} - isolated acceptance run starting`);
  await mkdir(artifactsRoot, { recursive: true });
  await writeFile(
    `${artifactsRoot}/environment.json`,
    `${JSON.stringify({ runID, mode: readingSharingProof ? "e04" : e03Proof ? "e03" : annotationsProof ? "e02" : "e01", node: process.version, nativeScheme, profile: annotationVisualProfile, destination: nativeDestination, fixtureDate: readingSharingProof ? null : "2026-10-05T00:00:00Z", clock: readingSharingProof ? "actual system UTC with fixture date recorded in e04-fixture.json" : "existing E02 fixture", acceptanceCase: readingSharingCase ?? null, apiURL: `http://localhost:${apiPort}/api/v1`, webURL: `http://localhost:${webPort}`, ticket: readingSharingProof ? "IPAD-E04" : e03Proof ? "IPAD-E03" : annotationsProof ? "IPAD-E02" : "IPAD-E01", annotationCase: pdfRecovery ? "pdf-recovery" : pdfHandoff ? "pdf-handoff" : recordedLayout ? "recorded-layout" : (annotationCase ?? "all"), nativeInputSubstitution: annotationsProof ? "debug-only deterministic Pencil/Scribble boundary" : readingSharingProof && nativeTests.some((name) => name.includes("A04")) ? "debug-only deterministic Pencil boundary" : null }, null, 2)}\n`,
  );
  if (readingSharingProof) {
    await writeFile(`${artifactsRoot}/acceptance-selection.json`, `${JSON.stringify(readingSharing, null, 2)}\n`);
    if (!process.argv.includes("--serve")) {
      const surfaces = [
        ...(!nativeOnly ? ["http"] : []),
        ...(process.argv.includes("--ui") ? ["native"] : []),
        ...(process.argv.includes("--web") ? ["browser"] : []),
      ];
      assertReadingSharingCoverage(readingSharing, surfaces);
      for (const file of !nativeOnly ? readingSharing.httpFiles : []) await lstat(join(root, file));
    }
    if (existingServer) {
      const directory = await realpath(existingServer);
      if (!directory.startsWith(`${root}test-results/ipad/`)) throw new Error("Retained E04 server must belong to this checkout's test results");
      const receiverEnvironment = JSON.parse(await readFile(join(directory, "receiver-environment.json"), "utf8"));
      const keys = [
        "IPAD_TEST_HARDCOVER_GRAPHQL_URL",
        "IPAD_TEST_HARDCOVER_TIMEOUT_MS",
        "IPAD_TEST_READWISE_BASE_URL",
        "IPAD_TEST_READWISE_TIMEOUT_MS",
        "IPAD_TEST_STORYGRAPH_BASE_URL",
        "IPAD_TEST_STORYGRAPH_TIMEOUT_MS",
        "IPAD_E04_RECEIVER_URL",
        "IPAD_E04_SMTP_PORT",
        "IPAD_E04_SMTP_HTTP_URL",
      ];
      for (const key of keys) {
        const value = receiverEnvironment[key];
        if (typeof value !== "string") throw new Error(`Retained E04 receiver is missing ${key}`);
        if (key.endsWith("URL")) {
          const url = new URL(value);
          if (url.protocol !== "http:" || url.hostname !== "127.0.0.1" || url.username || url.password)
            throw new Error("Retained receivers must use unauthenticated loopback HTTP");
        } else if (!/^\d+$/.test(value)) throw new Error("Retained receiver numeric settings must be decimal integers");
        env[key] = value;
      }
      for (const url of [`${env.IPAD_E04_API_URL}/auth/login-options`, `${env.IPAD_E04_RECEIVER_URL}/native-handoffs`]) {
        if (!(await fetch(url, { signal: AbortSignal.timeout(5000) })).ok) throw new Error("Retained E04 surfaces are unavailable");
      }
      await copyFile(join(directory, "e04-fixture.json"), join(artifactsRoot, "e04-fixture.json"));
      env.IPAD_E04_RESTART_DIRECTORY = join(directory, "core-restart");
      env.IPAD_KOBO_QUERY_OBSERVER = join(directory, "kobo-query-observer.json");
      await writeFile(
        `${artifactsRoot}/retained-server.json`,
        `${JSON.stringify({ source: directory, apiURL: env.IPAD_E04_BASE_URL, cleanupOwnership: "attached run owns only its native/browser/fault processes" }, null, 2)}\n`,
      );
      await writeFile(`${artifactsRoot}/receiver-environment.json`, `${JSON.stringify(receiverEnvironment, null, 2)}\n`);
    } else {
      externalReceivers = await startE04Receivers({ artifactDirectory: `${artifactsRoot}/receivers` });
      Object.assign(env, externalReceivers.env);
      await writeFile(`${artifactsRoot}/receiver-environment.json`, `${JSON.stringify(externalReceivers.env, null, 2)}\n`);
    }
  }
  if (!existingServer) {
    await createCoverFixture(env.IPAD_COVER_FIXTURE_DIR);
    if (epubProof || annotationsProof || readingSharingProof || e03Proof) {
      const prepared = readingSharingProof && process.env.IPAD_E04_PREPARED_READER_FIXTURE;
      if (prepared) {
        const fixtureDirectory = await realpath(prepared);
        if (!fixtureDirectory.startsWith(`${root}test-results/ipad/`))
          throw new Error("Prepared E04 reader fixture must belong to this checkout's test results");
        const destination = `${artifactsRoot}/reader-fixture`;
        await mkdir(destination, { recursive: true });
        const records = [];
        for (const name of ["reader-proof.epub", "recorded-narration.m4a", "recorded-narration-inspection.json"]) {
          const source = join(fixtureDirectory, name);
          const information = await lstat(source);
          if (!information.isFile() || information.isSymbolicLink()) throw new Error("Prepared E04 fixture must contain regular artifact files");
          const bytes = await readFile(source);
          records.push({ name, bytes: bytes.length, sha256: createHash("sha256").update(bytes).digest("hex") });
          await copyFile(source, join(destination, name));
        }
        await writeFile(`${artifactsRoot}/prepared-reader-fixture.json`, `${JSON.stringify({ source: fixtureDirectory, records }, null, 2)}\n`);
      } else {
        await command(process.execPath, ["scripts/ipad/reader-fixture.mjs", `${root}/test-results/ipad/${runID}/reader-fixture`]);
      }
    }
    await command(packageManager, ["ipad:contracts:check"]);
    if (skipBuild) {
      for (const relativePath of [
        "server/dist-ipad/test/ipad/harness.js",
        "packages/types/dist/index.js",
        "packages/plugin-api/dist/index.js",
        ...(process.argv.includes("--web") ? ["client/dist/index.html"] : []),
      ]) {
        if (!(await lstat(join(root, relativePath))).isFile()) throw new Error("Compiled isolated fixture output is absent");
      }
    } else {
      await command(packageManager, ["--filter", "@bookorbit/types", "build"]);
      await command(packageManager, ["--filter", "@bookorbit/plugin-api", "build"]);
      if (process.argv.includes("--web")) await command(packageManager, ["--filter", "client", "build-only"]);
    }
    await command(packageManager, ["--filter", "server", "e2e:db:prepare"]);
    await command(packageManager, ["--filter", "server", "db:migrate"]);
    if (!skipBuild) await command(packageManager, ["--filter", "server", "exec", "tsc", "-p", "tsconfig.ipad.json"]);
    await startCore();
  } else {
    await command(packageManager, ["ipad:contracts:check"]);
    if (process.argv.includes("--web")) await command(packageManager, ["--filter", "client", "build-only"]);
  }
  if (readingSharingProof && !existingServer) {
    restartMonitor = retainE04Core().catch((error) => {
      restartFailure = error;
      requestStop();
    });
  }
  if (e03Proof) await configureE03Fixtures();
  if (annotationsProof) {
    stopFaultProxy = await startFaultProxy({
      port: combinedFaultPort,
      ...(combinedRecovery || pdfRecovery
        ? {
            currentDocuments: async () => {
              if (!currentNativeDeviceID) throw new Error("Native device has not been selected");
              return publicExportDirectory(currentNativeDeviceID);
            },
          }
        : {}),
    });
  }
  if (process.argv.includes("--serve")) {
    const servingAt = Date.now();
    console.log(`[ipad.harness_serve] [start] runId=${runID} - retaining isolated test surfaces`);
    if (process.argv.includes("--web")) await startWeb();
    console.log(
      `[ipad.harness_serve] [end] runId=${runID} apiPort=${apiPort} durationMs=${Date.now() - servingAt} web=${Boolean(web)} ready=true - isolated test surfaces retained until interruption`,
    );
    await interrupt;
  } else {
    if (readingSharingProof && !nativeOnly) await runReadingSharingHTTP();
    if (annotationsProof && !nativeOnly && !combinedRecovery && !qa5BrowserOnly) {
      await command(process.execPath, [
        "--test",
        "--test-concurrency=1",
        ...(annotationCase ? [`--test-name-pattern=IPAD-E02-.*${annotationCase}`] : []),
        "scripts/ipad/annotation-http.test.mjs",
        "scripts/ipad/annotation-hub-http.test.mjs",
        "scripts/ipad/annotation-recovery-http.test.mjs",
        "scripts/ipad/pdf-annotation-page-http.test.mjs",
        "scripts/ipad/pdf-ink-http.test.mjs",
        "scripts/ipad/offline-delivery-http.test.mjs",
        "scripts/ipad/source-ink-http.test.mjs",
        "scripts/ipad/source-ink-window-http.test.mjs",
        "scripts/ipad/bookmark-retry-http.test.mjs",
        "scripts/ipad/source-pdf-cache-http.test.mjs",
      ]);
    }
    if (e03Proof) {
      await command(process.execPath, ["scripts/ipad/e03-runner.mjs", ...(e03Case ? [`--case=${e03Case}`] : [])]);
      if ((!e03Case || e03Case === "A03") && (process.argv.includes("--ui") || process.argv.includes("--web"))) await prepareE03MigrationFixtures();
    }
    if (!progressOnly && !annotationsProof && !readingSharingProof && !e03Proof)
      await command(process.execPath, ["--test", "scripts/ipad/http.test.mjs"]);
    if (organizationProof || crossClient) await command(process.execPath, ["--test", "scripts/ipad/organization-http.test.mjs"]);
    if (!annotationsProof && !readingSharingProof && !e03Proof) await command(process.execPath, ["--test", "scripts/ipad/progress-http.test.mjs"]);
    if (comicProof) await command(process.execPath, ["--test", "scripts/ipad/comic-http.test.mjs"]);
    if (process.argv.includes("--ui") && !stopFaultProxy) {
      stopFaultProxy = await startFaultProxy({
        port: combinedFaultPort,
        upstreamPort: apiPort,
        ...(readingSharingProof
          ? {
              currentDocuments: async () => {
                if (!currentNativeDeviceID) throw new Error("Native device has not been selected");
                return publicExportDirectory(currentNativeDeviceID);
              },
            }
          : {}),
      });
    }
    if (annotationConcurrent) {
      await startWeb();
      const outcomes = combinedRecovery
        ? await runCombinedNativeAndBrowser()
        : await Promise.allSettled([
            runNativeTests(),
            command(packageManager, ["exec", "playwright", "test", "--config", "scripts/ipad/playwright.config.mjs"]),
          ]);
      const failed = outcomes.filter((outcome) => outcome.status === "rejected");
      if (failed.length)
        throw new AggregateError(
          failed.map((outcome) => outcome.reason),
          "Concurrent native/browser annotation journey failed",
        );
      await runAdditionalAnnotationBrowserTests();
    }
    if (process.argv.includes("--ui") && !annotationConcurrent) await runNativeTests();
    if (readingSharingProof && (process.argv.includes("--ui") || process.argv.includes("--web"))) {
      const response = await fetch(`${env.IPAD_E04_RECEIVER_URL}/native-handoffs`, { signal: AbortSignal.timeout(5000) });
      if (!response.ok) throw new Error("Native E04 handoff receiver could not be read");
      const handoffs = await response.json();
      if (process.argv.includes("--web")) {
        for (const caseID of readingSharing.caseIDs)
          if (!handoffs[caseID]) throw new Error(`Native IPAD-E04-${caseID} did not submit an expected-state handoff`);
      }
      await writeFile(env.IPAD_E04_NATIVE_STATE_FILE, `${JSON.stringify(handoffs, null, 2)}\n`);
    }
    if (process.argv.includes("--web") && !annotationConcurrent) {
      await startWeb();
      if (inspectWeb) {
        const inspectionAt = Date.now();
        console.log(`[ipad.browser_inspection] [start] runId=${runID} - isolated native result and web server retained until interruption`);
        await interrupt;
        console.log(
          `[ipad.browser_inspection] [end] runId=${runID} durationMs=${Date.now() - inspectionAt} closed=true - retained browser inspection finished`,
        );
      } else {
        await command(packageManager, ["exec", "playwright", "test", "--config", browserConfig], {
          ...(qa5BrowserOnly ? { timeoutMs: 150_000 } : {}),
        });
        if (readingSharingProof) {
          const summary = JSON.parse(await readFile(`${artifactsRoot}/e04-browser-summary.json`, "utf8"));
          readingSharingBrowser = summary.stats;
          if (
            summary.stats.expected !== readingSharing.browser.length ||
            summary.stats.skipped !== 0 ||
            summary.stats.unexpected !== 0 ||
            summary.stats.flaky !== 0
          )
            throw new Error("E04 browser coverage requires every selected test to pass without skips, retries or failures");
        }
        if (e03Proof) await compareWebE03Visuals(artifactsRoot, annotationVisualProfile.name);
        await runAdditionalAnnotationBrowserTests();
      }
    }
  }
  if (readingSharingProof && !process.argv.includes("--serve")) {
    const pending = readingSharingVisuals.filter((report) => report.status === "pending-human-baseline");
    const result = {
      ticket: "IPAD-E04",
      runID,
      cases: readingSharing.caseIDs,
      functionalOnly,
      focusedNativeSelectors: process.env.IPAD_TEST_ONLY?.split(",") ?? null,
      reusedServer: existingServer ?? null,
      http: readingSharingHTTP ?? null,
      browser: readingSharingBrowser ?? null,
      nativeVisuals: readingSharingVisuals.length,
      pendingHumanBaselines: pending.length,
      integratedHumanWalkthrough: "outstanding",
      physicalAndLiveServiceChecks: "outstanding",
      acceptanceComplete: false,
    };
    await writeFile(`${artifactsRoot}/acceptance-result.json`, `${JSON.stringify(result, null, 2)}\n`);
    if (!functionalOnly && pending.length)
      throw new Error(`Native E04 visual gate has ${pending.length} screenshots awaiting human-reviewed baselines`);
  }
  if (restartFailure) throw restartFailure;
} finally {
  await cleanup();
}
console.log(`[ipad.harness] [end] runId=${runID} durationMs=${Date.now() - startedAt} cleaned=true - isolated acceptance run completed`);
