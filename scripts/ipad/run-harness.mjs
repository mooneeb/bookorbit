import { spawn } from "node:child_process";
import { randomBytes } from "node:crypto";
import { createWriteStream } from "node:fs";
import { mkdir, readFile, readdir, rm, writeFile } from "node:fs/promises";
import { createRequire } from "node:module";
import { basename } from "node:path";
import { fileURLToPath } from "node:url";
import { sanitizeLogValue } from "../../server/src/common/utils/log-sanitize.utils.ts";
import { startFaultProxy } from "./fault-proxy.mjs";
import { createCoverFixture } from "./cover-fixture.mjs";
import { annotationProfile } from "./annotation-matrix.mjs";
import { compareNativeAnnotationVisuals } from "./annotation-visual.mjs";

const startedAt = Date.now();
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
const artifactsRoot = `${root}/test-results/ipad/${runID}`;
let commandNumber = 0;
const annotationsProof = process.argv.includes("--annotations");
const annotationVisualProfile = annotationProfile(process.argv.find((argument) => argument.startsWith("--profile="))?.slice(10));
const nativeVisualProfile = annotationProfile(annotationVisualProfile.nativeProfile ?? annotationVisualProfile.name);
const nativeOnly = process.argv.includes("--native-only");
if (nativeOnly && (!annotationsProof || !process.argv.includes("--ui") || process.argv.includes("--web"))) {
  throw new Error("--native-only requires --annotations --ui and runs a focused native seam");
}
const annotationCase = process.argv.find((argument) => argument.startsWith("--case="))?.slice(7);
const annotationConcurrent = annotationsProof && annotationCase === "A05" && process.argv.includes("--ui") && process.argv.includes("--web");
if (annotationCase && (!annotationsProof || !/^A0[1-7]$/.test(annotationCase))) {
  throw new Error("--case requires --annotations and one of A01 through A07");
}
if (process.argv.includes("--list-annotations")) {
  console.log(
    "IPAD-E02-A01 passage notes\nIPAD-E02-A02 source PDF publication\nIPAD-E02-A03 source ink edits and Undo\nIPAD-E02-A04 explicit offline resources\nIPAD-E02-A05 concurrent reconciliation\nIPAD-E02-A06 source recovery\nIPAD-E02-A07 annotation hub",
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
if (annotationsProof && (readerProof || process.argv.includes("--cross-client"))) {
  throw new Error("Annotation acceptance uses the production app in its own focused run");
}
const epubProof = process.argv.includes("--epub-proof");
const comicProof = process.argv.includes("--comic-proof");
const organizationProof = process.argv.includes("--organization-proof");
const pdfReader = process.argv.includes("--pdf-reader");
const inspectWeb = process.argv.includes("--inspect-web");
if (inspectWeb && !process.argv.includes("--web")) throw new Error("Browser inspection requires --web");
const nativeScheme = readerProof ? "BookOrbitReaderProof" : annotationsProof ? "BookOrbitAnnotations" : "BookOrbit";
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
  process.env.IPAD_TEST_ONLY?.split(",") ??
  (annotationsProof ? ["BookOrbitUITests/AnnotationJourneyTests", "BookOrbitUITests/AnnotationHubJourneyTests"] : []);
if (nativeTests.some((name) => !new RegExp(`^${nativeTestBundle}/[A-Za-z_]\\w*(?:/[A-Za-z_]\\w*)?$`).test(name))) {
  throw new Error(`IPAD_TEST_ONLY must contain comma-separated ${nativeTestBundle} classes or methods`);
}
const env = {
  ...process.env,
  DATABASE_URL: databaseURL,
  E2E_DATABASE_URL: databaseURL,
  NODE_ENV: "test",
  APP_URL: "http://localhost:16484",
  IPAD_TEST_RUN: runID,
  IPAD_ANNOTATIONS_PROOF: annotationsProof ? "1" : "0",
  IPAD_ANNOTATION_CASE: annotationCase ?? "",
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
  ...(epubProof || annotationsProof ? { IPAD_READER_PROOF_EPUB: `${root}/test-results/ipad/${runID}/reader-fixture/reader-proof.epub` } : {}),
  JWT_SECRET: randomBytes(32).toString("hex"),
  SETUP_BOOTSTRAP_TOKEN: "",
  NATIVE_REDIRECT_URI: "bookorbit://oauth2-callback",
  NATIVE_ADDITIONAL_REDIRECT_URIS: "bookorbit-private://oauth2-callback",
};

async function command(cmd, args, { capture = false, ...options } = {}) {
  if (interrupted) throw new Error("iPad harness interrupted");
  await mkdir(`${artifactsRoot}/logs`, { recursive: true });
  const log = createWriteStream(`${artifactsRoot}/logs/${String(++commandNumber).padStart(3, "0")}-${basename(cmd)}.log`);
  return new Promise((resolve, reject) => {
    let output = "";
    const child = launch(cmd, args, { stdio: ["ignore", "pipe", "pipe"], ...options });
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
      log.end();
      reject(error);
    });
    child.once("close", (code, signal) => {
      children.delete(child);
      log.end(() => {
        if (code === 0) resolve(output);
        else reject(new Error(`${cmd} failed (${code ?? signal})`));
      });
    });
  });
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
  for (const child of children) void stop(child);
}
process.once("SIGINT", requestStop);
process.once("SIGTERM", requestStop);

let server;
let web;
let stopFaultProxy;
async function startWeb() {
  if (web) return;
  web = launch("pnpm", ["--filter", "client", "exec", "vite", "preview", "--host", "127.0.0.1", "--port", "16484", "--strictPort"], {
    env: { ...env, BOOKORBIT_API_TARGET: "http://localhost:16482" },
    stdio: "inherit",
  });
  const deadline = Date.now() + 30_000;
  while (true) {
    if (web.exitCode !== null) throw new Error("iPad web server exited before becoming ready");
    try {
      if ((await fetch("http://localhost:16484", { signal: AbortSignal.timeout(1000) })).ok) break;
    } catch {}
    if (Date.now() >= deadline) throw new Error("iPad web server did not become ready");
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
}

async function runAdditionalAnnotationBrowserTests() {
  if (!annotationsProof) return;
  const suites = [
    { config: "scripts/ipad/annotations-collection.config.mjs", cases: ["A01", "A03"], artifactSuffix: "collection" },
    { config: "scripts/ipad/source-ink-window-web.config.mjs", cases: ["A03"], artifactSuffix: "source-window" },
  ];
  for (const suite of suites) {
    if (annotationCase && !suite.cases.includes(annotationCase)) continue;
    await command(
      "pnpm",
      ["exec", "playwright", "test", "--config", suite.config, ...(annotationCase ? ["--grep", `IPAD-E02-${annotationCase}`] : [])],
      {
        env: { ...env, IPAD_TEST_RUN: `${runID}-${suite.artifactSuffix}` },
      },
    );
  }
}
async function stop(child) {
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
      signalGroup(child, "SIGTERM");
    } catch (error) {
      clearTimeout(timeout);
      reject(error);
    }
  });
  stops.set(child, stopped);
  return stopped;
}
async function cleanup() {
  await stopFaultProxy?.();
  const stopped = await Promise.allSettled([...children].map(stop));
  const client = new Client({ connectionString: "postgres://bookorbit:bookorbit@localhost:5432/postgres" });
  await client.connect();
  try {
    await client.query(`DROP DATABASE IF EXISTS "${databaseName}" WITH (FORCE)`);
  } finally {
    await client.end();
  }
  const failures = stopped.filter((result) => result.status === "rejected");
  if (failures.length)
    throw new AggregateError(
      failures.map((result) => result.reason),
      "iPad subprocess cleanup failed",
    );
}

async function runNativeTests() {
  const startedAt = Date.now();
  const nativeLock = "/tmp/bookorbit-ipad-xcode.lock";
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
    const artifacts = `${root}/test-results/ipad/${runID}`;
    await mkdir(artifacts, { recursive: true });
    const devices = JSON.parse(await command("xcrun", ["simctl", "list", "devices", "available", "--json"], { capture: true }));
    const explicitID = process.env.IPAD_TEST_DESTINATION?.match(/(?:^|,)id=([A-Fa-f0-9-]+)/)?.[1];
    const explicitName = process.env.IPAD_TEST_DESTINATION?.match(/(?:^|,)name=([^,]+)/)?.[1] ?? "BookOrbit Test iPad";
    const matches = Object.values(devices.devices)
      .flat()
      .filter((device) => (explicitID ? device.udid === explicitID : device.name === explicitName));
    if (matches.length !== 1) throw new Error("Select exactly one available test simulator with IPAD_TEST_DESTINATION");
    const selectedDevice = matches[0];
    if (selectedDevice.state === "Shutdown") await command("xcrun", ["simctl", "boot", selectedDevice.udid]);
    await command("xcrun", ["simctl", "bootstatus", selectedDevice.udid, "-b"]);
    if (annotationsProof) {
      const size = nativeVisualProfile.nativeDevice.includes("11") ? "11-inch" : "13-inch";
      if (!selectedDevice.deviceTypeIdentifier?.includes(size)) throw new Error(`Native profile requires an actual ${size} iPad simulator`);
      const contentSize =
        nativeVisualProfile.dynamicType === "accessibilityExtraExtraExtraLarge"
          ? "accessibility-extra-extra-extra-large"
          : nativeVisualProfile.dynamicType === "extraExtraExtraLarge"
            ? "extra-extra-extra-large"
            : "large";
      await command("xcrun", ["simctl", "ui", selectedDevice.udid, "appearance", nativeVisualProfile.colorScheme]);
      await command("xcrun", ["simctl", "ui", selectedDevice.udid, "content_size", contentSize]);
      const appearance = (await command("xcrun", ["simctl", "ui", selectedDevice.udid, "appearance"], { capture: true })).trim();
      const actualContentSize = (await command("xcrun", ["simctl", "ui", selectedDevice.udid, "content_size"], { capture: true })).trim();
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
    }
    if (!readerProof && !annotationsProof) {
      const destination = process.env.IPAD_TEST_DESTINATION;
      const device = destination?.match(/(?:^|,)id=([A-Fa-f0-9-]+)/)?.[1] ?? "BookOrbit Test iPad";
      await command("xcrun", [
        "simctl",
        "addmedia",
        device,
        `${env.IPAD_COVER_FIXTURE_DIR}/ebook-selected.png`,
        `${env.IPAD_COVER_FIXTURE_DIR}/ebook-large-selected.png`,
      ]);
    }
    if (annotationsProof) {
      const device = selectedDevice.udid;
      let installed = false;
      try {
        await command("xcrun", ["simctl", "get_app_container", device, "com.mooneeb.bookorbit.private", "data"], { capture: true });
        installed = true;
      } catch {}
      if (installed) await command("xcrun", ["simctl", "uninstall", device, "com.mooneeb.bookorbit.private"]);
      await command("xcrun", [
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
    await command("xcodegen", ["generate", "--spec", "ipad/project.yml"]);
    if (annotationsProof && !process.env.IPAD_TEST_ONLY) {
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
    try {
      const commonArguments = [
        "-project",
        "ipad/BookOrbit.xcodeproj",
        "-scheme",
        nativeScheme,
        ...(annotationsProof ? ["-testPlan", "AnnotationAcceptance", "-only-test-configuration", nativeVisualProfile.name] : []),
        "-parallel-testing-enabled",
        "NO",
        "-collect-test-diagnostics",
        "never",
        "-destination",
        process.env.IPAD_TEST_DESTINATION ?? "platform=iOS Simulator,name=BookOrbit Test iPad",
        "-derivedDataPath",
        "ipad/DerivedData",
        "CODE_SIGNING_ALLOWED=YES",
        "CODE_SIGN_IDENTITY=-",
      ];
      if (annotationsProof) {
        const preflight = "BookOrbitUITests/AnnotationProfilePerformanceTests/testIPADE02A01ApplySystemProfile";
        const nativeEnvironment = { ...env, IPAD_E02_PROFILE: nativeVisualProfile.name };
        await command(
          "xcodebuild",
          ["test", ...commonArguments, "-resultBundlePath", `${artifacts}/profile.xcresult`, `-only-testing:${preflight}`],
          { env: nativeEnvironment },
        );
        const profileSummaryText = await command(
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
        await command("xcrun", [
          "xcresulttool",
          "export",
          "attachments",
          "--path",
          `${artifacts}/profile.xcresult`,
          "--output-path",
          `${artifacts}/profile-attachments`,
        ]);
      }
      await command(
        "xcodebuild",
        [
          annotationsProof ? "test-without-building" : "test",
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
        { env: { ...env, IPAD_E02_PROFILE: nativeVisualProfile.name } },
      );
    } catch (error) {
      nativeFailure = error;
    }
    if (!interrupted) {
      try {
        const summaryText = await command(
          "xcrun",
          ["xcresulttool", "get", "test-results", "summary", "--path", `${artifacts}/native.xcresult`, "--format", "json"],
          { capture: true },
        );
        await writeFile(`${artifacts}/native-summary.json`, summaryText);
        const exported = await command(
          "xcrun",
          ["xcresulttool", "export", "attachments", "--path", `${artifacts}/native.xcresult`, "--output-path", `${artifacts}/native-attachments`],
          { capture: true },
        );
        await writeFile(`${artifacts}/native-attachments.log`, exported);
        if (annotationsProof) await compareNativeAnnotationVisuals(artifacts, nativeVisualProfile.name);
        const summary = JSON.parse(summaryText);
        if (
          summary.totalTestCount < 1 ||
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
      } catch (error) {
        nativeFailure ??= error;
      }
    }
    if (nativeFailure) throw nativeFailure;
    if (interrupted) throw new Error("Native verification interrupted");
  } catch (error) {
    console.error(
      `[ipad.ui] [fail] runId=${runID} durationMs=${Date.now() - startedAt} errorClass=${error instanceof Error ? error.name : "Error"} error="${sanitizeLogValue(error instanceof Error ? error.message : String(error))}" - native verification failed`,
    );
    throw error;
  } finally {
    await rm(nativeLock, { recursive: true, force: true });
  }
}

try {
  console.log(`[ipad.harness] [start] runId=${runID} annotations=${annotationsProof} - isolated acceptance run starting`);
  await mkdir(artifactsRoot, { recursive: true });
  await writeFile(
    `${artifactsRoot}/environment.json`,
    `${JSON.stringify({ runID, node: process.version, nativeScheme, profile: annotationVisualProfile, destination: process.env.IPAD_TEST_DESTINATION ?? "platform=iOS Simulator,name=BookOrbit Test iPad", fixtureDate: "2026-10-05T00:00:00Z", apiURL: "http://localhost:16482/api/v1", webURL: "http://localhost:16484", annotationCase: annotationCase ?? "all", nativeInputSubstitution: annotationsProof ? "debug-only deterministic Pencil/Scribble boundary" : null }, null, 2)}\n`,
  );
  await createCoverFixture(env.IPAD_COVER_FIXTURE_DIR);
  if (epubProof || annotationsProof) {
    await command(process.execPath, ["scripts/ipad/reader-fixture.mjs", `${root}/test-results/ipad/${runID}/reader-fixture`]);
  }
  await command("pnpm", ["ipad:contracts:check"]);
  await command("pnpm", ["--filter", "@bookorbit/types", "build"]);
  await command("pnpm", ["--filter", "@bookorbit/plugin-api", "build"]);
  if (process.argv.includes("--web")) await command("pnpm", ["--filter", "client", "build-only"]);
  await command("pnpm", ["--filter", "server", "e2e:db:prepare"]);
  await command("pnpm", ["--filter", "server", "db:migrate"]);
  await command("pnpm", ["--filter", "server", "exec", "tsc", "-p", "tsconfig.ipad.json"]);
  server = launch(process.execPath, ["server/dist-ipad/test/ipad/harness.js"], { stdio: ["ignore", "pipe", "inherit"] });
  server.stdout.pipe(createWriteStream(`${artifactsRoot}/server.log`));
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
  if (annotationsProof) stopFaultProxy = await startFaultProxy();
  if (process.argv.includes("--serve")) {
    const servingAt = Date.now();
    console.log(`[ipad.harness_serve] [start] runId=${runID} - retaining isolated test surfaces`);
    if (process.argv.includes("--web")) await startWeb();
    console.log(
      `[ipad.harness_serve] [end] runId=${runID} apiPort=16482 durationMs=${Date.now() - servingAt} web=${Boolean(web)} ready=true - isolated test surfaces retained until interruption`,
    );
    await interrupt;
  } else {
    if (annotationsProof && !nativeOnly) {
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
    if (!progressOnly && !annotationsProof) await command(process.execPath, ["--test", "scripts/ipad/http.test.mjs"]);
    if (organizationProof || crossClient) await command(process.execPath, ["--test", "scripts/ipad/organization-http.test.mjs"]);
    if (!annotationsProof) await command(process.execPath, ["--test", "scripts/ipad/progress-http.test.mjs"]);
    if (comicProof) await command(process.execPath, ["--test", "scripts/ipad/comic-http.test.mjs"]);
    if (process.argv.includes("--ui") && !stopFaultProxy) stopFaultProxy = await startFaultProxy();
    if (annotationConcurrent) {
      await startWeb();
      const outcomes = await Promise.allSettled([
        runNativeTests(),
        command("pnpm", ["exec", "playwright", "test", "--config", "scripts/ipad/playwright.config.mjs"]),
      ]);
      const failed = outcomes.filter((outcome) => outcome.status === "rejected");
      if (failed.length)
        throw new AggregateError(
          failed.map((outcome) => outcome.reason),
          "Concurrent native/browser A05 failed",
        );
      await runAdditionalAnnotationBrowserTests();
    }
    if (process.argv.includes("--ui") && !annotationConcurrent) await runNativeTests();
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
        await command("pnpm", ["exec", "playwright", "test", "--config", "scripts/ipad/playwright.config.mjs"]);
        await runAdditionalAnnotationBrowserTests();
      }
    }
  }
} finally {
  await cleanup();
}
console.log(`[ipad.harness] [end] runId=${runID} durationMs=${Date.now() - startedAt} cleaned=true - isolated acceptance run completed`);
