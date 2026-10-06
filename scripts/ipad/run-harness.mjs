import { spawn } from "node:child_process";
import { randomBytes } from "node:crypto";
import { mkdir, writeFile } from "node:fs/promises";
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";
import { sanitizeLogValue } from "../../server/src/common/utils/log-sanitize.utils.ts";
import { startFaultProxy } from "./fault-proxy.mjs";
import { createCoverFixture } from "./cover-fixture.mjs";

const root = fileURLToPath(new URL("../../", import.meta.url));
const require = createRequire(new URL("../../server/package.json", import.meta.url));
const { Client } = require("pg");
const databaseName = `bookorbit_ipad_${process.pid}_e2e`;
const databaseURL = `postgres://bookorbit:bookorbit@localhost:5432/${databaseName}`;
const runID = `run-${process.pid}-${Date.now()}`;
const progressOnly = process.argv.includes("--progress-only");
if (progressOnly && ["--ui", "--web", "--serve"].some((flag) => process.argv.includes(flag))) {
  throw new Error("Focused progress HTTP verification runs without UI, browser or retained-server modes");
}
const crossClient = process.argv.includes("--cross-client");
const metadataProof = process.argv.includes("--metadata-proof");
const metadataClearsProof = process.argv.includes("--metadata-clears-proof");
const coverProof = process.argv.includes("--cover-proof");
const readerProof = process.argv.includes("--reader-proof");
const epubProof = process.argv.includes("--epub-proof");
const comicProof = process.argv.includes("--comic-proof");
const organizationProof = process.argv.includes("--organization-proof");
const pdfReader = process.argv.includes("--pdf-reader");
const inspectWeb = process.argv.includes("--inspect-web");
if (inspectWeb && !process.argv.includes("--web")) throw new Error("Browser inspection requires --web");
const nativeScheme = readerProof ? "BookOrbitReaderProof" : "BookOrbit";
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
const nativeTests = process.env.IPAD_TEST_ONLY?.split(",") ?? [];
if (nativeTests.some((name) => !new RegExp(`^${nativeScheme}UITests/[A-Za-z_]\\w*(?:/[A-Za-z_]\\w*)?$`).test(name))) {
  throw new Error(`IPAD_TEST_ONLY must contain comma-separated ${nativeScheme}UITests classes or methods`);
}
const env = {
  ...process.env,
  DATABASE_URL: databaseURL,
  E2E_DATABASE_URL: databaseURL,
  NODE_ENV: "test",
  APP_URL: "http://localhost:16484",
  IPAD_TEST_RUN: runID,
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
  ...(epubProof ? { IPAD_READER_PROOF_EPUB: `${root}/test-results/ipad/${runID}/reader-fixture/reader-proof.epub` } : {}),
  JWT_SECRET: randomBytes(32).toString("hex"),
  SETUP_BOOTSTRAP_TOKEN: "",
  NATIVE_REDIRECT_URI: "bookorbit://oauth2-callback",
  NATIVE_ADDITIONAL_REDIRECT_URIS: "bookorbit-private://oauth2-callback",
};

async function command(cmd, args, { capture = false, ...options } = {}) {
  if (interrupted) throw new Error("iPad harness interrupted");
  return new Promise((resolve, reject) => {
    let output = "";
    const child = launch(cmd, args, { stdio: capture ? ["ignore", "pipe", "inherit"] : "inherit", ...options });
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
    child.once("error", reject);
    child.once("exit", (code, signal) => {
      children.delete(child);
      if (code === 0) {
        resolve(output);
      } else reject(new Error(`${cmd} failed (${code ?? signal})`));
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
  console.log(`[ipad.ui] [start] runId=${runID} filtered=${Boolean(process.env.IPAD_TEST_ONLY)} - native verification starting`);
  try {
    const artifacts = `${root}/test-results/ipad/${runID}`;
    await mkdir(artifacts, { recursive: true });
    if (!process.env.IPAD_TEST_DESTINATION) {
      const devices = JSON.parse(await command("xcrun", ["simctl", "list", "devices", "available", "--json"], { capture: true }));
      const matches = Object.values(devices.devices)
        .flat()
        .filter((device) => device.name === "BookOrbit Test iPad");
      if (matches.length !== 1) throw new Error("Select exactly one test simulator with IPAD_TEST_DESTINATION");
      const device = matches[0];
      if (device.state === "Shutdown") await command("xcrun", ["simctl", "boot", device.udid]);
      await command("xcrun", ["simctl", "bootstatus", device.udid, "-b"]);
    }
    if (!readerProof) {
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
    await command("xcodegen", ["generate", "--spec", "ipad/project.yml"]);
    let nativeFailure;
    try {
      await command("xcodebuild", [
        "test",
        "-project",
        "ipad/BookOrbit.xcodeproj",
        "-scheme",
        nativeScheme,
        "-parallel-testing-enabled",
        "NO",
        "-collect-test-diagnostics",
        "never",
        "-destination",
        process.env.IPAD_TEST_DESTINATION ?? "platform=iOS Simulator,name=BookOrbit Test iPad",
        "-derivedDataPath",
        "ipad/DerivedData",
        "-resultBundlePath",
        `${artifacts}/native.xcresult`,
        "CODE_SIGNING_ALLOWED=YES",
        "CODE_SIGN_IDENTITY=-",
        ...(nativeTests.length
          ? nativeTests.map((name) => `-only-testing:${name}`)
          : comicProof
            ? ["-only-testing:BookOrbitReaderProofUITests/ComicReaderProofTests"]
            : pdfReader
              ? ["-only-testing:BookOrbitUITests/EntryJourneyTests/testIPADE01A03ProductionPDFCurlAndResume"]
              : readerProof && !epubProof
                ? ["-only-testing:BookOrbitReaderProofUITests/PDFReaderProofTests"]
                : []),
      ]);
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
  }
}

try {
  await createCoverFixture(env.IPAD_COVER_FIXTURE_DIR);
  if (epubProof) {
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
  if (process.argv.includes("--serve")) {
    await interrupt;
  } else {
    if (!progressOnly) await command(process.execPath, ["--test", "scripts/ipad/http.test.mjs"]);
    if (organizationProof || crossClient) await command(process.execPath, ["--test", "scripts/ipad/organization-http.test.mjs"]);
    await command(process.execPath, ["--test", "scripts/ipad/progress-http.test.mjs"]);
    if (process.argv.includes("--ui")) stopFaultProxy = await startFaultProxy();
    if (process.argv.includes("--ui")) await runNativeTests();
    if (process.argv.includes("--web")) {
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
      if (inspectWeb) {
        console.log(`[ipad.browser_inspection] [start] runId=${runID} - isolated native result and web server retained until interruption`);
        await interrupt;
      } else {
        await command("pnpm", ["exec", "playwright", "test", "--config", "scripts/ipad/playwright.config.mjs"]);
      }
    }
  }
} finally {
  await cleanup();
}
