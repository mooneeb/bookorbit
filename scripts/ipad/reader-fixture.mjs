import { execFile } from "node:child_process";
import { createWriteStream } from "node:fs";
import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { createRequire } from "node:module";
import { join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";

const execute = promisify(execFile);
const require = createRequire(new URL("../../server/package.json", import.meta.url));
const { ZipArchive } = require("archiver");
const sentences = ["Alpha. Cafe. Omega.", "First chapter ends here.", "Second chapter begins here.", "Second chapter ends here."];

export async function createReaderProofFixture(folder) {
  await mkdir(folder, { recursive: true });
  const temporary = await mkdtemp(join(folder, "proof-audio-"));
  try {
    for (const [index, sentence] of sentences.entries()) {
      const source = join(temporary, `${index}.aiff`);
      await execute("/usr/bin/say", ["-v", "Fred", "-r", "140", "-o", source, sentence]);
      const inspection = await execute("/opt/homebrew/bin/ffprobe", ["-v", "error", "-show_entries", "format=duration", "-of", "json", source]);
      if (Number(JSON.parse(inspection.stdout).format.duration) >= 6)
        throw new Error("Fixture utterance exceeds its independently specified six-second clip");
      await execute("/opt/homebrew/bin/ffmpeg", [
        "-v",
        "error",
        "-y",
        "-i",
        source,
        "-af",
        "apad=whole_dur=6",
        "-t",
        "6",
        "-ar",
        "24000",
        "-ac",
        "1",
        "-c:a",
        "pcm_s16le",
        join(temporary, `${index}.wav`),
      ]);
    }
    const inputs = sentences.flatMap((_, index) => ["-i", join(temporary, `${index}.wav`)]);
    const audioPath = join(folder, "recorded-narration.m4a");
    await execute("/opt/homebrew/bin/ffmpeg", [
      "-v",
      "error",
      "-y",
      ...inputs,
      "-filter_complex",
      "[0:a][1:a][2:a][3:a]concat=n=4:v=0:a=1[out]",
      "-map",
      "[out]",
      "-c:a",
      "aac",
      "-b:a",
      "48k",
      audioPath,
    ]);
    const inspection = await execute("/opt/homebrew/bin/ffprobe", [
      "-v",
      "error",
      "-show_entries",
      "format=duration:stream=codec_name,sample_rate,channels",
      "-of",
      "json",
      audioPath,
    ]);
    const audio = JSON.parse(inspection.stdout);
    if (Math.abs(Number(audio.format.duration) - 24) > 0.1 || audio.streams[0].codec_name !== "aac")
      throw new Error("Recorded fixture is not the specified 24-second AAC file");
    await execute("/opt/homebrew/bin/ffmpeg", ["-v", "error", "-i", audioPath, "-f", "null", "-"]);
    await writeFile(
      join(folder, "recorded-narration-inspection.json"),
      JSON.stringify(
        { ...audio, sentences, clipBoundariesSeconds: [0, 6, 12, 18, 24], inputKind: "locally synthesized, pre-recorded fixture" },
        null,
        2,
      ) + "\n",
    );

    const files = {
      "META-INF/container.xml":
        '<?xml version="1.0" encoding="UTF-8"?><container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" version="1.0"><rootfiles><rootfile full-path="OPS/package.opf" media-type="application/oebps-package+xml"/></rootfiles></container>',
      "OPS/package.opf": `<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid">
<metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="uid">urn:uuid:5a34bb53-7d00-4c22-9951-efe92f143bc1</dc:identifier><dc:title>Native renderer proof</dc:title><dc:language>en</dc:language><meta property="dcterms:modified">2026-10-05T00:00:00Z</meta><meta property="media:duration">00:00:24.000</meta><meta property="media:duration" refines="#mo1">00:00:12.000</meta><meta property="media:duration" refines="#mo2">00:00:12.000</meta><meta property="media:active-class">proof-speaking</meta></metadata>
<manifest><item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/><item id="c1" href="c1.xhtml" media-type="application/xhtml+xml" media-overlay="mo1"/><item id="c2" href="c2.xhtml" media-type="application/xhtml+xml" media-overlay="mo2"/><item id="mo1" href="c1.smil" media-type="application/smil+xml"/><item id="mo2" href="c2.smil" media-type="application/smil+xml"/><item id="css" href="style.css" media-type="text/css"/><item id="audio" href="narration.m4a" media-type="audio/mp4"/></manifest>
<spine page-progression-direction="ltr"><itemref id="c1ref" idref="c1"/><itemref id="c2ref" idref="c2"/></spine></package>`,
      "OPS/nav.xhtml":
        '<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" lang="en" xml:lang="en"><head><title>Contents</title></head><body><nav epub:type="toc"><h1>Contents</h1><ol><li><a href="c1.xhtml#p1">One</a></li><li><a href="c2.xhtml#p3">Two</a></li></ol></nav></body></html>',
      "OPS/c1.xhtml":
        '<html xmlns="http://www.w3.org/1999/xhtml" lang="en" xml:lang="en"><head><title>One</title><link rel="stylesheet" href="style.css"/></head><body><p id="p1">Alpha &#x1F600; cafe&#x301; omega.</p><p id="p2">First chapter ends here.</p></body></html>',
      "OPS/c2.xhtml":
        '<html xmlns="http://www.w3.org/1999/xhtml" lang="en" xml:lang="en"><head><title>Two</title><link rel="stylesheet" href="style.css"/></head><body><p id="p3">Second chapter begins here.</p><p id="p4">Second chapter ends here.</p></body></html>',
      "OPS/style.css":
        "body { font-family: serif; font-size: 20px; line-height: 1.5; } p { margin: 0 0 1em; } .proof-speaking { outline: 2px solid currentColor; }",
      "OPS/c1.smil":
        '<smil xmlns="http://www.w3.org/ns/SMIL" version="3.0"><body><seq><par><text src="c1.xhtml#p1"/><audio src="narration.m4a" clipBegin="0s" clipEnd="6s"/></par><par><text src="c1.xhtml#p2"/><audio src="narration.m4a" clipBegin="6s" clipEnd="12s"/></par></seq></body></smil>',
      "OPS/c2.smil":
        '<smil xmlns="http://www.w3.org/ns/SMIL" version="3.0"><body><seq><par><text src="c2.xhtml#p3"/><audio src="narration.m4a" clipBegin="12s" clipEnd="18s"/></par><par><text src="c2.xhtml#p4"/><audio src="narration.m4a" clipBegin="18s" clipEnd="24s"/></par></seq></body></smil>',
    };
    const epubPath = join(folder, "reader-proof.epub");
    const archive = new ZipArchive({ zlib: { level: 9 } });
    const destination = createWriteStream(epubPath);
    const completed = new Promise((resolve, reject) => {
      destination.once("close", resolve);
      destination.once("error", reject);
      archive.once("error", reject);
    });
    archive.pipe(destination);
    const date = new Date("2026-10-05T00:00:00Z");
    archive.append("application/epub+zip", { name: "mimetype", store: true, date });
    for (const [name, contents] of Object.entries(files)) archive.append(contents, { name, date });
    archive.append(await readFile(audioPath), { name: "OPS/narration.m4a", store: true, date });
    await Promise.all([archive.finalize(), completed]);
    return { epubPath, audioPath, audio };
  } finally {
    await rm(temporary, { recursive: true, force: true });
  }
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  if (!process.argv[2]) throw new Error("Supply a dedicated fixture output directory");
  const result = await createReaderProofFixture(resolve(process.argv[2]));
  console.log(JSON.stringify({ epubPath: result.epubPath, audioPath: result.audioPath, durationSeconds: Number(result.audio.format.duration) }));
}
