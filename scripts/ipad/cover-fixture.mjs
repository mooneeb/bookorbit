import { mkdir, writeFile, copyFile } from "node:fs/promises";
import { createRequire } from "node:module";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

const require = createRequire(new URL("../../server/package.json", import.meta.url));
const sharp = require("sharp");

export async function createCoverFixture(folder) {
  await mkdir(folder, { recursive: true });
  for (const [name, width, height, color, caption] of [
    ["ebook-extracted", 512, 768, "rgb(180,52,48)", "Original ebook cover"],
    ["audio-extracted", 512, 512, "rgb(30,150,78)", "Original audio cover"],
    ["ebook-selected", 640, 960, "rgb(48,112,192)", "Chosen ebook cover"],
  ]) {
    const image = Buffer.from(
      `<svg xmlns="http://www.w3.org/2000/svg" width="${width}" height="${height}"><rect width="100%" height="100%" fill="${color}"/><text x="50%" y="50%" text-anchor="middle" fill="white" font-family="Helvetica" font-size="32">${caption}</text></svg>`,
    );
    const prepared = sharp(image).png();
    if (name === "ebook-selected")
      prepared.withExif({ IFD0: { DateTime: "2030:01:01 12:00:00" }, IFD2: { DateTimeOriginal: "2030:01:01 12:00:00" } });
    await writeFile(join(folder, `${name}.png`), await prepared.toBuffer());
  }
  const original = Buffer.from(
    '<svg xmlns="http://www.w3.org/2000/svg" width="2400" height="3600"><rect x="128" width="2272" height="3600" fill="rgb(144,64,160)"/><text x="55%" y="50%" text-anchor="middle" fill="white" font-family="Helvetica" font-size="120">Original resolution</text></svg>',
  );
  await writeFile(
    join(folder, "ebook-large-selected.png"),
    await sharp(original)
      .withExif({ IFD0: { DateTime: "2031:01:01 12:00:00" }, IFD2: { DateTimeOriginal: "2031:01:01 12:00:00" } })
      .png()
      .toBuffer(),
  );
  await copyFile(fileURLToPath(new URL("../../server/test/ipad/fixtures/cover-audio.m4a", import.meta.url)), join(folder, "cover-audio.m4a"));
}
