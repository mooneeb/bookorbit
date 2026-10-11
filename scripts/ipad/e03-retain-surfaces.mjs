import { execFile, spawn } from "node:child_process";
import { createHash, randomUUID } from "node:crypto";
import { copyFile, mkdir, readFile, rename, stat, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";
import { startRequestAdminFixture } from "./e03-request-admin-fixture.mjs";
import { startE03ResponseProxy } from "./e03-response-proxy.mjs";

const execute = promisify(execFile);
const root = fileURLToPath(new URL("../../", import.meta.url));
const runID = process.argv[2];
if (!/^run-[0-9]+-[0-9]+$/.test(runID ?? "")) throw new Error("Supply a retained isolated E03 run ID");
if (process.argv.slice(3).some((value) => value !== "--web")) throw new Error("Unknown retained surface argument");
const artifacts = join(root, "test-results/ipad", runID);
const metadata = JSON.parse(await readFile(join(artifacts, "environment.json"), "utf8"));
if (metadata.runID !== runID || metadata.mode !== "e03") throw new Error("Retained E03 run metadata is required");
const fixture = JSON.parse(await readFile(join(artifacts, "e03-fixture.json"), "utf8"));
if (!(await stat(fixture.contentRoot)).isDirectory()) throw new Error("Retained temporary content is absent");
const base = "http://localhost:16482/api/v1";
const envPath = join(artifacts, "e03-runtime.env");
let protocol;
let proxy;
let web;
let session;

async function request(path, body, method = body ? "POST" : "GET") {
  const response = await fetch(`${base}/${path}`, {
    method,
    headers: { ...(session ? { Authorization: `Bearer ${session.accessToken}` } : {}), ...(body ? { "content-type": "application/json" } : {}) },
    body: body ? JSON.stringify(body) : undefined,
    signal: AbortSignal.timeout(30_000),
  });
  if (!response.ok) throw new Error(`Retained fixture configuration failed: ${method} ${path} (${response.status})`);
  return response.status === 204 ? undefined : response.json();
}

async function configure(path, body) {
  const result = await request(path);
  const existing = (path === "admin/request-indexers" ? result.indexers : result.clients).filter((item) => item.name === body.name);
  if (existing.length > 1) throw new Error(`Ambiguous retained protocol configuration: ${path}`);
  return request(existing[0] ? `${path}/${existing[0].id}` : path, body, existing[0] ? "PUT" : "POST");
}

async function retainWeb() {
  let listeners;
  try {
    ({ stdout: listeners } = await execute("lsof", ["-tiTCP:16484", "-sTCP:LISTEN"]));
  } catch (error) {
    if (error.code !== 1) throw error;
  }
  let pid;
  if (listeners?.trim()) {
    const pids = [...new Set(listeners.trim().split(/\s+/))];
    if (pids.length !== 1) throw new Error("Exactly one isolated web preview listener is required");
    pid = Number(pids[0]);
    const { stdout: cwd } = await execute("lsof", ["-a", "-p", String(pid), "-d", "cwd", "-Fn"]);
    const { stdout: command } = await execute("ps", ["-p", String(pid), "-o", "command="]);
    if (!cwd.split("\n").includes(`n${join(root, "client")}`) || !command.includes("vite") || !command.includes("preview")) {
      throw new Error("The web preview listener belongs to another workspace");
    }
  } else {
    web = spawn(
      process.env.IPAD_PNPM_EXECUTABLE ?? "pnpm",
      ["--filter", "client", "exec", "vite", "preview", "--host", "127.0.0.1", "--port", "16484", "--strictPort"],
      {
        cwd: root,
        env: { ...process.env, BOOKORBIT_API_TARGET: "http://localhost:16482" },
        stdio: "inherit",
      },
    );
    pid = web.pid;
  }
  const deadline = Date.now() + 30_000;
  while (true) {
    if (web && web.exitCode !== null) throw new Error("Retained web preview exited before readiness");
    try {
      if ((await fetch("http://localhost:16484", { signal: AbortSignal.timeout(1_000) })).ok) break;
    } catch {}
    if (Date.now() >= deadline) throw new Error("Retained web preview did not become ready");
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  return pid;
}

try {
  session = await request("auth/login", {
    username: "ipad-owner",
    password: process.env.IPAD_FIXTURE_PASSWORD ?? "IpadFixture123",
    clientKind: "native",
    deviceLabel: "E03 retained fixture preparation",
  });
  protocol = await startRequestAdminFixture({ port: 0, localDownloadPath: fixture.downloadRoot });
  const downloadPath = dirname(protocol.filePath);
  await configure("admin/request-indexers", {
    name: "E03 controlled source",
    adapterType: "torznab",
    baseUrl: `${protocol.origin}/torznab/api`,
    allowPrivateAddress: true,
    enabled: true,
  });
  await configure("admin/download-clients", {
    name: "E03 controlled client",
    adapterType: "qbittorrent",
    baseUrl: protocol.origin,
    allowPrivateAddress: true,
    enabled: true,
    category: "bookorbit",
    useHardlinks: false,
    pathMappings: [{ remotePath: downloadPath, localPath: downloadPath }],
  });
  await request("auth/logout", { refreshToken: session.refreshToken });
  session = undefined;
  proxy = await startE03ResponseProxy({
    port: 16488,
    seedDock: async () => {
      await mkdir(fixture.dockPath, { recursive: true });
      const filename = `E03 scanned source ${randomUUID()}.pdf`;
      const path = join(fixture.dockPath, filename);
      await copyFile(fixture.uploadFile, path);
      return {
        filename,
        sha256: createHash("sha256")
          .update(await readFile(path))
          .digest("hex"),
      };
    },
  });
  const webPID = process.argv.includes("--web") ? await retainWeb() : undefined;
  const largeUploadSHA256 = createHash("sha256")
    .update(await readFile(fixture.largeUploadFile))
    .digest("hex");
  const values = {
    IPAD_E03_PROTOCOL_URL: protocol.origin,
    TEST_RUNNER_IPAD_E03_PROTOCOL_URL: protocol.origin,
    IPAD_E03_DOWNLOAD_PATH: downloadPath,
    IPAD_E03_FAULT_URL: proxy.origin,
    IPAD_E03_SERVER_URL: proxy.origin,
    TEST_RUNNER_IPAD_E03_FAULT_URL: proxy.origin,
    TEST_RUNNER_IPAD_E03_SERVER_URL: proxy.origin,
    IPAD_E03_LARGE_UPLOAD_SHA256: largeUploadSHA256,
    TEST_RUNNER_IPAD_E03_LARGE_UPLOAD_SHA256: largeUploadSHA256,
  };
  const lines = (await readFile(envPath, "utf8")).split("\n").filter(Boolean);
  const quote = (value) => `'${String(value).replaceAll("'", "'\\''")}'`;
  for (const [key, value] of Object.entries(values)) {
    const line = `export ${key}=${quote(value)}`;
    const index = lines.findIndex((existing) => existing.startsWith(`export ${key}=`));
    if (index === -1) lines.push(line);
    else lines[index] = line;
  }
  const temporary = `${envPath}.${process.pid}.tmp`;
  await writeFile(temporary, `${lines.join("\n")}\n`, { mode: 0o600 });
  await rename(temporary, envPath);
  const ready = {
    runID,
    ready: true,
    surfacePID: process.pid,
    protocolOrigin: protocol.origin,
    proxyOrigin: proxy.origin,
    webPID,
    envPath,
    databaseReseeded: false,
  };
  await writeFile(join(artifacts, "e03-surfaces-runtime.json"), `${JSON.stringify(ready, null, 2)}\n`);
  console.log(JSON.stringify(ready));
  await new Promise((resolve) => {
    process.once("SIGINT", resolve);
    process.once("SIGTERM", resolve);
  });
} finally {
  if (session) await request("auth/logout", { refreshToken: session.refreshToken });
  web?.kill("SIGTERM");
  await proxy?.close();
  await protocol?.close();
}
