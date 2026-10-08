import { ZipArchive } from 'archiver';
import { createWriteStream } from 'node:fs';
import sharp from 'sharp';

export async function createComicFixture(path: string): Promise<void> {
  const archive = new ZipArchive({ zlib: { level: 6 } });
  const output = createWriteStream(path);
  const completed = new Promise<void>((resolve, reject) => {
    output.once('close', resolve);
    output.once('error', reject);
    archive.once('error', reject);
  });
  archive.pipe(output);
  for (const [name, page] of [
    ['page-10.png', 3],
    ['page-2.png', 2],
    ['page-1.png', 1],
  ] as const) {
    const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="600" height="800"><rect width="600" height="800" fill="white"/><text x="300" y="160" text-anchor="middle" font-family="Arial" font-size="36" fill="black">Orbit comic: page ${page}</text><rect x="60" y="240" width="480" height="480" fill="none" stroke="black" stroke-width="4"/></svg>`;
    archive.append(await sharp(Buffer.from(svg)).png().toBuffer(), { name });
  }
  await archive.finalize();
  await completed;
}
