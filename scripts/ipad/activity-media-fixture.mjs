import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { createHash } from "node:crypto";
import { createWriteStream } from "node:fs";
import { mkdir, mkdtemp, readFile, rename, rm, stat, writeFile } from "node:fs/promises";
import { createRequire } from "node:module";
import { basename, dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";

const execute = promisify(execFile);
const require = createRequire(new URL("../../server/package.json", import.meta.url));
const { ZipArchive } = require("archiver");
const unzipper = require("unzipper");
export const ACTIVITY_MEDIA_SECONDS = 60;
export const ACTIVITY_AUDIO_TITLE = "E04 activity audio";
export const ACTIVITY_EPUB_TITLE = "E04 activity narration";
export const ACTIVITY_PARAGRAPH = [
  "The quiet library opened beside the river before sunrise. A reader carried a notebook to the broad window and watched the light move across the shelves. Every book held a different journey, and today there was enough time to listen carefully.",
  "Outside, a small boat passed beneath the bridge. Its steady movement reminded the reader that a journey continues one moment at a time. The room was warm, the chair was comfortable, and the story began with a clear and patient voice.",
  "A traveler followed a winding path through an orchard. Leaves stirred above the stones while a distant bell marked the morning hour. At the next gate, a friend offered fresh water and described the hills that waited beyond the village road.",
  "Together they studied a paper map, tracing the path with one finger. They chose the shaded trail and left room in their plan for unexpected discoveries. There was no hurry. The purpose was to notice the world and remember the people along the way.",
  "When the reader paused to look outside again, the river had become bright silver. The same story would still be waiting after a brief interruption. A remembered place, a clear voice, and a carefully kept record would make the next part easy to find.",
].join(" ");

function digest(bytes) {
  return createHash("sha256").update(bytes).digest("hex");
}
const commandOptions = { timeout: 90_000, maxBuffer: 1024 * 1024 };

async function inspectAudio(path) {
  const result = await execute(
    "/opt/homebrew/bin/ffprobe",
    ["-v", "error", "-show_entries", "format=duration:stream=codec_name,sample_rate,channels", "-of", "json", path],
    commandOptions,
  );
  const media = JSON.parse(result.stdout);
  const duration = Number(media.format.duration);
  assert.ok(
    duration >= ACTIVITY_MEDIA_SECONDS && duration <= ACTIVITY_MEDIA_SECONDS + 0.1,
    "Activity media must contain at least sixty seconds of real playback",
  );
  assert.equal(media.streams.length, 1);
  assert.equal(media.streams[0].codec_name, "aac");
  assert.equal(media.streams[0].channels, 1);
  assert.equal(media.streams[0].sample_rate, "24000");
  assert.ok((await stat(path)).size <= 2 * 1024 * 1024);
  await execute("/opt/homebrew/bin/ffmpeg", ["-v", "error", "-i", path, "-f", "null", "-"], commandOptions);
  return { durationSeconds: duration, codec: "aac", sampleRate: 24000, channels: 1 };
}

export async function inspectActivityMediaFixture(folder) {
  const audioPath = join(folder, "audio", "activity-audio.m4a");
  const epubPath = join(folder, "narration", "activity-narration.epub");
  const audio = await inspectAudio(audioPath);
  assert.ok((await stat(epubPath)).size <= 4 * 1024 * 1024);
  const zip = await unzipper.Open.file(epubPath);
  const names = zip.files.map(({ path }) => path);
  assert.equal(names.length, 7);
  assert.equal(new Set(names).size, names.length);
  const entry = async (name) => {
    const file = zip.files.find(({ path }) => path === name);
    assert.ok(file, `Activity EPUB is missing ${name}`);
    assert.ok(file.uncompressedSize <= 2 * 1024 * 1024);
    return file.buffer();
  };
  assert.equal((await entry("mimetype")).toString(), "application/epub+zip");
  const opf = (await entry("OPS/package.opf")).toString();
  const chapter = (await entry("OPS/chapter.xhtml")).toString();
  const smil = (await entry("OPS/chapter.smil")).toString();
  assert.ok(opf.includes('media-overlay="narration"'));
  assert.ok(opf.includes('<meta property="media:duration">00:01:00.000</meta>'));
  assert.ok(chapter.includes(`<p id="activity-passage">${ACTIVITY_PARAGRAPH}</p>`));
  const paragraphWords = ACTIVITY_PARAGRAPH.split(/\s+/).length;
  assert.ok(paragraphWords >= 200);
  assert.match(smil, /<text src="chapter\.xhtml#activity-passage"\/>/);
  assert.match(smil, /<audio src="narration\.m4a" clipBegin="0s" clipEnd="60s"\/>/);
  assert.equal((smil.match(/<par>/g) ?? []).length, 1);
  const audioBytes = await readFile(audioPath);
  assert.equal(digest(await entry("OPS/narration.m4a")), digest(audioBytes), "Recorded narration must contain the inspected real AAC bytes");
  return {
    audioPath,
    epubPath,
    audioDurationSeconds: audio.durationSeconds,
    narrationDurationSeconds: ACTIVITY_MEDIA_SECONDS,
    paragraphWords,
    audioSHA256: digest(audioBytes),
    epubSHA256: digest(await readFile(epubPath)),
    audioTitle: ACTIVITY_AUDIO_TITLE,
    epubTitle: ACTIVITY_EPUB_TITLE,
    inputKind: "locally synthesized recorded narration, actual sixty-second playback",
  };
}

export async function ensureActivityMediaFixture(folder) {
  folder = resolve(folder);
  let exists = true;
  try {
    await stat(folder);
  } catch (error) {
    if (error.code !== "ENOENT") throw error;
    exists = false;
  }
  if (exists) return inspectActivityMediaFixture(folder);
  await mkdir(dirname(folder), { recursive: true });
  const temporary = await mkdtemp(join(dirname(folder), `${basename(folder)}-building-`));
  try {
    await mkdir(join(temporary, "audio"));
    await mkdir(join(temporary, "narration"));
    const spoken = join(temporary, "spoken.aiff");
    await execute("/usr/bin/say", ["-v", "Fred", "-r", "220", "-o", spoken, ACTIVITY_PARAGRAPH], commandOptions);
    const probe = await execute(
      "/opt/homebrew/bin/ffprobe",
      ["-v", "error", "-show_entries", "format=duration", "-of", "json", spoken],
      commandOptions,
    );
    const sourceDuration = Number(JSON.parse(probe.stdout).format.duration);
    const tempo = sourceDuration / ACTIVITY_MEDIA_SECONDS;
    assert.ok(tempo >= 0.5 && tempo <= 2, "Recorded utterance must fit without extreme tempo changes");
    const audioPath = join(temporary, "audio", "activity-audio.m4a");
    await execute(
      "/opt/homebrew/bin/ffmpeg",
      [
        "-v",
        "error",
        "-y",
        "-i",
        spoken,
        "-af",
        `atempo=${tempo.toFixed(8)},apad=whole_dur=60`,
        "-t",
        "60",
        "-ar",
        "24000",
        "-ac",
        "1",
        "-c:a",
        "aac",
        "-b:a",
        "64k",
        "-map_metadata",
        "-1",
        audioPath,
      ],
      commandOptions,
    );
    await inspectAudio(audioPath);
    const epubPath = join(temporary, "narration", "activity-narration.epub");
    const archive = new ZipArchive({ zlib: { level: 6 } });
    const output = createWriteStream(epubPath);
    const completed = new Promise((resolve, reject) => {
      output.once("close", resolve);
      output.once("error", reject);
      archive.once("error", reject);
    });
    archive.pipe(output);
    const date = new Date("2026-10-10T00:00:00Z");
    archive.append("application/epub+zip", { name: "mimetype", store: true, date });
    const files = {
      "META-INF/container.xml":
        '<?xml version="1.0"?><container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" version="1.0"><rootfiles><rootfile full-path="OPS/package.opf" media-type="application/oebps-package+xml"/></rootfiles></container>',
      "OPS/package.opf": `<?xml version="1.0"?><package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="uid">urn:uuid:504b3e04-60aa-4000-8000-000000000001</dc:identifier><dc:title>${ACTIVITY_EPUB_TITLE}</dc:title><dc:language>en</dc:language><meta property="dcterms:modified">2026-10-10T00:00:00Z</meta><meta property="media:duration">00:01:00.000</meta><meta property="media:duration" refines="#narration">00:01:00.000</meta></metadata><manifest><item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/><item id="chapter" href="chapter.xhtml" media-type="application/xhtml+xml" media-overlay="narration"/><item id="narration" href="chapter.smil" media-type="application/smil+xml"/><item id="audio" href="narration.m4a" media-type="audio/mp4"/></manifest><spine><itemref idref="chapter"/></spine></package>`,
      "OPS/nav.xhtml":
        '<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" lang="en"><head><title>Contents</title></head><body><nav epub:type="toc"><ol><li><a href="chapter.xhtml#activity-passage">The quiet library</a></li></ol></nav></body></html>',
      "OPS/chapter.xhtml": `<html xmlns="http://www.w3.org/1999/xhtml" lang="en" xml:lang="en"><head><title>The quiet library</title></head><body><p id="activity-passage">${ACTIVITY_PARAGRAPH}</p></body></html>`,
      "OPS/chapter.smil":
        '<smil xmlns="http://www.w3.org/ns/SMIL" version="3.0"><body><seq><par><text src="chapter.xhtml#activity-passage"/><audio src="narration.m4a" clipBegin="0s" clipEnd="60s"/></par></seq></body></smil>',
    };
    for (const [name, text] of Object.entries(files)) archive.append(text, { name, date });
    archive.append(await readFile(audioPath), { name: "OPS/narration.m4a", store: true, date });
    await Promise.all([archive.finalize(), completed]);
    await rm(spoken);
    const inspection = await inspectActivityMediaFixture(temporary);
    await writeFile(
      join(temporary, "inspection.json"),
      `${JSON.stringify({ ...inspection, audioPath: join(folder, "audio", "activity-audio.m4a"), epubPath: join(folder, "narration", "activity-narration.epub"), sourceDuration, tempo }, null, 2)}\n`,
    );
    await rename(temporary, folder);
    return await inspectActivityMediaFixture(folder);
  } finally {
    await rm(temporary, { recursive: true, force: true });
  }
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  assert.ok(process.argv[2], "Supply a dedicated activity fixture directory");
  console.log(JSON.stringify(await ensureActivityMediaFixture(process.argv[2])));
}
