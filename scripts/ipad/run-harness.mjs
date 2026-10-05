import { spawn } from "node:child_process";
import { randomBytes } from "node:crypto";
import { mkdir } from "node:fs/promises";
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";

const root = fileURLToPath(new URL("../../", import.meta.url));
const require = createRequire(new URL("../../server/package.json", import.meta.url));
const { Client } = require("pg");
const databaseName = `bookorbit_ipad_${process.pid}_e2e`;
const databaseURL = `postgres://bookorbit:bookorbit@localhost:5432/${databaseName}`;
const runID = `run-${process.pid}-${Date.now()}`;
const env = {
  ...process.env,
  DATABASE_URL: databaseURL,
  E2E_DATABASE_URL: databaseURL,
  NODE_ENV: "test",
  APP_URL: "http://localhost:16484",
  IPAD_TEST_RUN: runID,
  JWT_SECRET: randomBytes(32).toString("hex"),
  SETUP_BOOTSTRAP_TOKEN: "",
  NATIVE_REDIRECT_URI: "bookorbit://oauth2-callback",
  NATIVE_ADDITIONAL_REDIRECT_URIS: "bookorbit-private://oauth2-callback",
};

async function command(cmd, args, options = {}) {
  if (interrupted) throw new Error("iPad harness interrupted");
  await new Promise((resolve, reject) => {
    const child = launch(cmd, args, { stdio: "inherit", ...options });
    child.once("error", reject);
    child.once("exit", (code, signal) => {
      children.delete(child);
      if (code === 0) {
        resolve();
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

try {
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
    await command(process.execPath, ["--test", "scripts/ipad/http.test.mjs"]);
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
      await command("pnpm", ["exec", "playwright", "test", "--config", "scripts/ipad/playwright.config.mjs"]);
    }
    if (process.argv.includes("--ui")) {
      await mkdir(`${root}/test-results/ipad/${runID}`, { recursive: true });
      await command("xcodegen", ["generate", "--spec", "ipad/project.yml"]);
      await command("xcodebuild", [
        "test",
        "-project",
        "ipad/BookOrbit.xcodeproj",
        "-scheme",
        "BookOrbit",
        "-parallel-testing-enabled",
        "NO",
        "-collect-test-diagnostics",
        "never",
        "-destination",
        process.env.IPAD_TEST_DESTINATION ?? "platform=iOS Simulator,name=BookOrbit Test iPad",
        "-derivedDataPath",
        "ipad/DerivedData",
        "-resultBundlePath",
        `test-results/ipad/${runID}/native.xcresult`,
        "CODE_SIGNING_ALLOWED=YES",
        "CODE_SIGN_IDENTITY=-",
      ]);
    }
  }
} finally {
  await cleanup();
}
