import { createServer } from "node:http";
import { createHash, generateKeyPairSync, sign } from "node:crypto";
import { createRequire } from "node:module";
import { mkdir, mkdtemp, writeFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
const require = createRequire(new URL("../../server/package.json", import.meta.url));
const { PDFDocument, StandardFonts } = require("pdf-lib");

export async function startRequestAdminFixture({ port = 16502, localDownloadPath } = {}) {
  if (localDownloadPath) await mkdir(localDownloadPath, { recursive: true });
  const folder = await mkdtemp(join(localDownloadPath ?? tmpdir(), "bookorbit-request-protocol-"));
  const filePath = join(folder, "Request fixture.pdf");
  const pluginFilePath = join(folder, "E03 controlled plugin.mjs");
  await writeFile(
    pluginFilePath,
    `export default { apiVersion: 1, type: 'e03-native-plugin', label: 'E03 native plugin', version: '1.0.0', requiresCredential: false, mediaKinds: ['ebook'], usesCategories: false, seedsBack: false, search: async () => [], test: async () => ({ success: true }), resolveFile: async () => ({ url: 'https://example.invalid/book.pdf' }) };`,
  );
  const pdf = await PDFDocument.create();
  pdf.setTitle("Request fixture");
  pdf.setAuthor("Fixture Author");
  const page = pdf.addPage();
  const font = await pdf.embedFont(StandardFonts.Helvetica);
  page.drawText("Readable request fixture: delivered through controlled source and client.", { x: 40, y: 700, size: 14, font });
  const bytes = await pdf.save();
  await writeFile(filePath, bytes);
  const hash = "a".repeat(40);
  let added = false;
  let failSearch = false;
  let failAdd = false;
  let held = false;
  let managerUnavailable = false;
  const server = createServer(async (request, response) => {
    const url = new URL(request.url, "http://fixture");
    const json = (body) => {
      response.setHeader("content-type", "application/json");
      response.end(JSON.stringify(body));
    };
    if (url.pathname === "/control") {
      failSearch = url.searchParams.get("failSearch") === "true";
      failAdd = url.searchParams.get("failAdd") === "true";
      held = url.searchParams.get("held") === "true";
      if (url.searchParams.has("orphan")) added = url.searchParams.get("orphan") === "true";
      if (url.searchParams.has("managerUnavailable")) managerUnavailable = url.searchParams.get("managerUnavailable") === "true";
      if (url.searchParams.get("reset") === "true") added = false;
      json({ failSearch, failAdd, held, added });
    } else if (url.pathname === "/torznab/api" && url.searchParams.get("t") === "caps") {
      response.setHeader("content-type", "application/xml");
      response.end(
        '<caps><server title="E03 controlled Torznab" version="1.0"/><searching><search available="yes"/></searching><categories><category id="7020" name="Books"/></categories></caps>',
      );
    } else if (url.pathname === "/torznab/api") {
      if (failSearch) {
        response.statusCode = 503;
        response.end("controlled source unavailable");
        return;
      }
      response.setHeader("content-type", "application/rss+xml");
      response.end(
        `<rss version="2.0" xmlns:torznab="http://torznab.com/schemas/2015/feed"><channel><title>E03 controlled releases</title><item><title>Request fixture PDF</title><guid>e03-readable-pdf</guid><link>magnet:?xt=urn:btih:${hash}</link><size>${bytes.length}</size><torznab:attr name="infohash" value="${hash}"/><torznab:attr name="seeders" value="10"/><torznab:attr name="format" value="pdf"/></item></channel></rss>`,
      );
    } else if (url.pathname === "/api/v2/auth/login") {
      response.setHeader("set-cookie", "SID=e03-fixture; HttpOnly");
      response.end("Ok.");
    } else if (url.pathname === "/api/v2/app/version") {
      response.end("v5.0.0");
    } else if (url.pathname === "/api/v2/torrents/add") {
      for await (const _ of request) {
      }
      if (failAdd) {
        response.statusCode = 503;
        response.end("controlled client unavailable");
        return;
      }
      added = true;
      response.end("Ok.");
    } else if (url.pathname === "/api/v2/torrents/info") {
      json(
        added
          ? [
              {
                hash,
                infohash_v1: hash,
                name: "Request fixture",
                state: held ? "downloading" : "uploading",
                progress: held ? 0.25 : 1,
                size: bytes.length,
                total_size: bytes.length,
                downloaded: held ? Math.floor(bytes.length / 4) : bytes.length,
                amount_left: held ? Math.floor(bytes.length * 0.75) : 0,
                content_path: filePath,
                save_path: folder,
                category: "bookorbit",
                ratio: 0,
                uploaded: 0,
                seeding_time: 0,
              },
            ]
          : [],
      );
    } else if (url.pathname === "/api/v2/torrents/delete") {
      for await (const _ of request) {
      }
      added = false;
      response.end("Ok.");
    } else if (url.pathname === "/api/v2/torrents/createCategory" || url.pathname === "/api/v2/torrents/setShareLimits") {
      for await (const _ of request) {
      }
      response.end("Ok.");
    } else if (url.pathname === "/api/v1/system/status") {
      json({ version: "1.0.0" });
    } else if (url.pathname === "/api/v1/indexer") {
      if (request.headers["x-api-key"] !== "fixture-prowlarr-key") {
        response.statusCode = 401;
        json({ error: "Invalid controlled manager credential" });
        return;
      }
      json(
        managerUnavailable
          ? []
          : [
              {
                id: 42,
                name: "E03 managed source",
                protocol: "torrent",
                implementation: "Torznab",
                enable: true,
                priority: 1,
                fields: [
                  { name: "torrentBaseSettings.seedRatio", value: 1.5 },
                  { name: "torrentBaseSettings.seedTime", value: 60 },
                ],
              },
            ],
      );
    } else {
      response.statusCode = 404;
      response.end("Unknown controlled protocol route");
    }
  });
  await new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(port, "127.0.0.1", resolve);
  });
  return {
    origin: `http://127.0.0.1:${server.address().port}`,
    filePath,
    pluginFilePath,
    close: async () => {
      await new Promise((resolve) => server.close(resolve));
      await rm(folder, { recursive: true, force: true });
    },
  };
}

export function createSignedRequestPluginUpdate({ origin, type = "e03-signed-plugin" }) {
  const url = new URL(origin);
  if (url.protocol !== "https:") throw new Error("Signed plugin update fixture requires an HTTPS origin");
  const { publicKey, privateKey } = generateKeyPairSync("ed25519");
  const ed25519PublicKey = publicKey.export({ format: "jwk" }).x;
  const manifestUrl = new URL("plugin.json", `${origin.replace(/\/$/, "")}/`).href;
  const sourceUrl = new URL("index.mjs", `${origin.replace(/\/$/, "")}/`).href;
  const source = (version) =>
    `export default { apiVersion: 1, type: '${type}', label: 'E03 signed plugin', version: '${version}', update: ${JSON.stringify({ manifestUrl, ed25519PublicKey })}, requiresCredential: false, mediaKinds: ['ebook'], usesCategories: false, seedsBack: false, search: async () => [], test: async () => ({ success: true }), resolveFile: async () => ({ url: 'https://example.invalid/book.pdf' }) };`;
  const initialSource = source("1.0.0");
  const updateSource = source("1.1.0");
  return {
    initialSource,
    updateSource,
    manifest: {
      schemaVersion: 1,
      type,
      version: "1.1.0",
      sourceUrl,
      sha256: createHash("sha256").update(updateSource).digest("hex"),
      signature: sign(null, Buffer.from(updateSource), privateKey).toString("base64"),
    },
    ed25519PublicKey,
    manifestUrl,
  };
}
