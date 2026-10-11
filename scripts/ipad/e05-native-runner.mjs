import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { mkdir, readFile, rm, writeFile } from "node:fs/promises";
import { join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { compareE05Captures } from "./e05-visual.mjs";

const root = fileURLToPath(new URL("../../", import.meta.url));
const artifacts = process.env.IPAD_TEST_ARTIFACTS ? resolve(process.env.IPAD_TEST_ARTIFACTS) : undefined;
if (!artifacts?.startsWith(join(root, "test-results/ipad/"))) throw new Error("Source the isolated e05-runtime.env before using this runner");
const deviceID = process.env.IPAD_E05_DEVICE_ID;
assert.match(deviceID ?? "", /^[A-Fa-f0-9-]{36}$/, "Select IPAD_E05_DEVICE_ID from an available iPad simulator");
const profile = process.env.IPAD_E05_PROFILE ?? "pro13-portrait-light";
const buildOnly = process.argv.includes("--build-only");
const reuseBuild = process.argv.includes("--reuse-build");
const deadline = Date.now() + 12 * 60_000;
const lock = "/tmp/bookorbit-ipad-xcode.lock";
let sequence = 0;
await mkdir(artifacts, { recursive: true });

async function command(executable, args, capture = false) {
  const remaining = deadline - Date.now();
  if (remaining <= 0) throw new Error("E05 native run exceeded its 12-minute budget");
  return new Promise((resolve, reject) => {
    const child = spawn(executable, args, {
      cwd: root,
      env: {
        ...process.env,
        TEST_RUNNER_IPAD_E05_PROFILE: profile,
        TEST_RUNNER_IPAD_E05_SERVER_URL: process.env.IPAD_E05_SERVER_URL ?? "http://localhost:16486",
      },
      stdio: ["ignore", "pipe", "pipe"],
    });
    let output = "";
    const timeout = setTimeout(() => child.kill("SIGTERM"), remaining);
    const collect = (chunk) => {
      output += chunk;
      if (!capture) process.stdout.write(chunk);
    };
    child.stdout.on("data", collect);
    child.stderr.on("data", collect);
    const stop = () => child.kill("SIGTERM");
    process.once("SIGINT", stop);
    process.once("SIGTERM", stop);
    child.once("error", reject);
    child.once("close", async (code, signal) => {
      clearTimeout(timeout);
      process.removeListener("SIGINT", stop);
      process.removeListener("SIGTERM", stop);
      await writeFile(join(artifacts, `e05-native-${buildOnly ? "build" : "run"}-command-${++sequence}.log`), output);
      if (code === 0) resolve(output);
      else reject(new Error(`${executable} failed (${code ?? signal}); see native command log`));
    });
  });
}

await mkdir(lock);
try {
  await writeFile(join(lock, "owner.json"), JSON.stringify({ pid: process.pid, artifacts, role: buildOnly ? "builder" : "tester" }));
  const devices = JSON.parse(await command("xcrun", ["simctl", "list", "devices", "available", "--json"], true));
  const device = Object.values(devices.devices)
    .flat()
    .find((item) => item.udid === deviceID);
  assert.ok(
    device && device.deviceTypeIdentifier.includes(profile.includes("pro11") ? "11-inch" : "13-inch"),
    "Use the iPad size requested by the visual profile",
  );
  if (device.state === "Shutdown") await command("xcrun", ["simctl", "boot", deviceID]);
  await command("xcrun", ["simctl", "bootstatus", deviceID, "-b"]);
  await command("xcrun", ["simctl", "ui", deviceID, "appearance", profile.includes("dark") ? "dark" : "light"]);
  await command("xcrun", [
    "simctl",
    "ui",
    deviceID,
    "content_size",
    profile.includes("large-type") ? "accessibility-extra-extra-extra-large" : "large",
  ]);
  await command("xcrun", [
    "simctl",
    "status_bar",
    deviceID,
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
  const common = [
    "-project",
    "ipad/BookOrbit.xcodeproj",
    "-scheme",
    "BookOrbit",
    "-parallel-testing-enabled",
    "NO",
    "-collect-test-diagnostics",
    "never",
    "-destination",
    `platform=iOS Simulator,id=${deviceID}`,
    "-derivedDataPath",
    "ipad/DerivedData",
    "CODE_SIGNING_ALLOWED=YES",
    "CODE_SIGN_IDENTITY=-",
  ];
  if (!reuseBuild) {
    await command("xcodegen", ["generate", "--spec", "ipad/project.yml"]);
    await command("xcodebuild", ["build-for-testing", ...common]);
  }
  if (!buildOnly) {
    const tests = process.env.IPAD_TEST_ONLY?.split(",") ?? ["BookOrbitUITests/E05AcceptanceJourneyTests"];
    assert.ok(tests.every((test) => /^BookOrbitUITests\/E05AcceptanceJourneyTests(?:\/testIPADE05A0[1-6][A-Za-z0-9_]*)?$/.test(test)));
    let failure;
    try {
      await command("xcodebuild", [
        "test-without-building",
        ...common,
        "-resultBundlePath",
        join(artifacts, "native.xcresult"),
        ...tests.map((test) => `-only-testing:${test}`),
      ]);
    } catch (error) {
      failure = error;
    }
    const summary = JSON.parse(
      await command(
        "xcrun",
        ["xcresulttool", "get", "test-results", "summary", "--path", join(artifacts, "native.xcresult"), "--format", "json"],
        true,
      ),
    );
    await writeFile(join(artifacts, "native-summary.json"), `${JSON.stringify(summary, null, 2)}\n`);
    await command(
      "xcrun",
      ["xcresulttool", "export", "attachments", "--path", join(artifacts, "native.xcresult"), "--output-path", join(artifacts, "native-attachments")],
      true,
    );
    await writeFile(
      join(artifacts, "e05-native-profile.json"),
      JSON.stringify({ deviceID, device: device.name, profile, runtime: "iOS26", narrowWindowVerified: false, reduceMotionVerified: false, tests }),
    );
    if (failure) throw failure;
    assert.ok(
      summary.totalTestCount > 0 &&
        summary.passedTests === summary.totalTestCount &&
        summary.failedTests === 0 &&
        summary.skippedTests === 0 &&
        summary.expectedFailures === 0,
    );
    await compareE05Captures(artifacts, profile, "native");
  }
} finally {
  await rm(lock, { recursive: true, force: true });
}
