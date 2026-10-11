import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdir, mkdtemp, readFile, rm, stat, writeFile } from "node:fs/promises";
import { createRequire } from "node:module";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { promisify } from "node:util";
import { ensureActivityMediaFixture } from "./activity-media-fixture.mjs";

const execute = promisify(execFile);
const require = createRequire(new URL("../../server/package.json", import.meta.url));
const unzipper = require("unzipper");
const { XMLParser } = require("fast-xml-parser");
const xml = new XMLParser({ ignoreAttributes: false, removeNSPrefix: true });
const sha = (bytes) => createHash("sha256").update(bytes).digest("hex");

async function measuredAudio(path) {
  const { stdout } = await execute(
    "/opt/homebrew/bin/ffprobe",
    ["-v", "error", "-show_entries", "format=duration:stream=codec_name,sample_rate,channels", "-of", "json", path],
    { timeout: 30_000 },
  );
  const measured = JSON.parse(stdout);
  assert.ok(Number(measured.format.duration) >= 60 && Number(measured.format.duration) <= 60.1);
  assert.equal(measured.streams[0].codec_name, "aac");
  assert.equal(measured.streams[0].channels, 1);
  assert.equal(measured.streams[0].sample_rate, "24000");
  await execute("/opt/homebrew/bin/ffmpeg", ["-v", "error", "-i", path, "-f", "null", "-"], { timeout: 30_000 });
  return Number(measured.format.duration);
}

async function verifyArtifacts(audioPath, epubPath, directory) {
  const audioDuration = await measuredAudio(audioPath);
  const zip = await unzipper.Open.file(epubPath);
  assert.equal(zip.files[0].path, "mimetype");
  const bytes = async (path) => {
    const entry = zip.files.find((file) => file.path === path);
    assert.ok(entry && entry.uncompressedSize <= 2 * 1024 * 1024);
    return entry.buffer();
  };
  assert.equal((await bytes("mimetype")).toString(), "application/epub+zip");
  const chapter = xml.parse((await bytes("OPS/chapter.xhtml")).toString()).html.body.p;
  assert.equal(chapter["@_id"], "activity-passage");
  const words = chapter["#text"].trim().split(/\s+/).length;
  assert.ok(words > 200, `TTS must have one continuous paragraph, measured words=${words}`);
  const sequence = xml.parse((await bytes("OPS/chapter.smil")).toString()).smil.body.seq.par;
  assert.ok(!Array.isArray(sequence));
  assert.equal(sequence.text["@_src"], "chapter.xhtml#activity-passage");
  assert.equal(sequence.audio["@_src"], "narration.m4a");
  assert.equal(sequence.audio["@_clipBegin"], "0s");
  assert.equal(sequence.audio["@_clipEnd"], "60s");
  const narration = await bytes("OPS/narration.m4a");
  assert.equal(sha(narration), sha(await readFile(audioPath)));
  const extracted = join(directory, "independently-extracted-narration.m4a");
  await writeFile(extracted, narration);
  const narrationDuration = await measuredAudio(extracted);
  return { audioDurationSeconds: audioDuration, narrationDurationSeconds: narrationDuration, paragraphWords: words, audioSHA256: sha(narration) };
}

test("E04 activity media: actual decodable sixty-second audio and EPUB narration, long continuous text and immutable reuse", async (context) => {
  const temporary = await mkdtemp(join(tmpdir(), "bookorbit-e04-media-proof-"));
  try {
    const directory = process.env.IPAD_E04_ACTIVITY_ARTIFACT_DIR ?? join(temporary, "fixture");
    const fixture = await ensureActivityMediaFixture(directory);
    const before = { audio: await stat(fixture.audioPath), epub: await stat(fixture.epubPath) };
    const inspected = await verifyArtifacts(fixture.audioPath, fixture.epubPath, temporary);
    assert.deepEqual(await ensureActivityMediaFixture(directory), fixture);
    assert.equal((await stat(fixture.audioPath)).mtimeMs, before.audio.mtimeMs);
    assert.equal((await stat(fixture.epubPath)).mtimeMs, before.epub.mtimeMs);
    context.diagnostic(JSON.stringify({ ...inspected, audioPath: fixture.audioPath, epubPath: fixture.epubPath }));
  } finally {
    await rm(temporary, { recursive: true, force: true });
  }
});

test(
  "IPAD-E04-A01-Media-HTTP: five isolated readers discover and fetch real long media, restricted scope cannot download",
  { skip: !process.env.IPAD_E04_BASE_URL },
  async (context) => {
    const base = process.env.IPAD_E04_BASE_URL;
    assert.match(base, /^http:\/\/(127\.0\.0\.1|localhost):\d+$/);
    const request = (path, token, body) =>
      fetch(`${base}/api/v1/${path}`, {
        method: body ? "POST" : "GET",
        headers: { ...(token ? { Authorization: `Bearer ${token}` } : {}), ...(body ? { "Content-Type": "application/json" } : {}) },
        ...(body ? { body: JSON.stringify(body) } : {}),
        signal: AbortSignal.timeout(30_000),
      });
    const json = async (path, token, body) => {
      const response = await request(path, token, body);
      assert.ok(response.ok, `${path}: HTTP ${response.status}`);
      return response.json();
    };
    const login = async (username) =>
      (
        await json("auth/login", undefined, {
          username,
          password: "IpadFixture123",
          clientKind: "native",
          deviceLabel: "Actual activity media verification",
        })
      ).accessToken;
    const directory = await mkdtemp(join(tmpdir(), "bookorbit-e04-downloaded-media-"));
    try {
      let expected;
      let token;
      for (const kind of ["listen", "tts", "recorded", "offline", "unknown"]) {
        token = await login(`ipad-e04-activity-${kind}`);
        const ids = {};
        for (const [name, title, format] of [
          ["audio", "E04 activity audio", "m4a"],
          ["epub", "E04 activity narration", "epub"],
        ]) {
          const matches = await json(`books/search?q=${encodeURIComponent(title)}&limit=10`, token);
          assert.ok(matches.length <= 10);
          const book = matches.find((item) => item.title === title);
          assert.ok(book, `${kind} cannot discover ${title}`);
          const detail = await json(`books/${book.id}`, token);
          const file = detail.files.find((item) => item.format === format);
          assert.ok(file && file.id === detail.primaryFileId);
          ids[`${name}BookId`] = book.id;
          ids[`${name}FileId`] = file.id;
        }
        if (expected) assert.deepEqual(ids, expected);
        else expected = ids;
      }
      const download = async (fileId, path) => {
        const response = await request(`books/files/${fileId}/download`, token);
        assert.equal(response.status, 200);
        assert.ok(Number(response.headers.get("content-length")) <= 4 * 1024 * 1024);
        const bytes = Buffer.from(await response.arrayBuffer());
        assert.ok(bytes.length > 0 && bytes.length <= 4 * 1024 * 1024);
        await writeFile(path, bytes);
      };
      const audioPath = join(directory, "audio.m4a");
      const epubPath = join(directory, "narration.epub");
      await download(expected.audioFileId, audioPath);
      await download(expected.epubFileId, epubPath);
      const inspection = await verifyArtifacts(audioPath, epubPath, directory);
      const overlay = await json(`epub/${expected.epubBookId}/media-overlay?fileId=${expected.epubFileId}`, token);
      assert.equal(overlay.durationSeconds, 60);
      assert.equal(overlay.items.length, 1);
      assert.equal(overlay.items[0].clipBeginSeconds, 0);
      assert.equal(overlay.items[0].clipEndSeconds, 60);
      const delivered = await request(
        `epub/${expected.epubBookId}/media-overlay/file/OPS/narration.m4a?fileId=${expected.epubFileId}&sectionIndex=0`,
        token,
      );
      assert.equal(delivered.status, 200);
      assert.equal(sha(Buffer.from(await delivered.arrayBuffer())), inspection.audioSHA256);
      const denied = await login("ipad-restricted");
      for (const fileId of [expected.audioFileId, expected.epubFileId])
        assert.ok([403, 404].includes((await request(`books/files/${fileId}/download`, denied)).status));
      context.diagnostic(JSON.stringify({ ...expected, ...inspection, source: "authenticated public discovery, downloads and overlay delivery" }));
    } finally {
      await rm(directory, { recursive: true, force: true });
    }
  },
);
