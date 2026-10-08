import { BadRequestException } from '@nestjs/common';
import * as unzipper from 'unzipper';
import { readCbzZipIndex } from './cbz-zip-reader';

const openZipFileWithOptions = unzipper.Open.file as (filePath: string, options: { tailSize: number }) => Promise<unzipper.CentralDirectory>;

export async function openBoundedEpubArchive(filePath: string): Promise<unzipper.CentralDirectory> {
  const index = await readCbzZipIndex(filePath, { maxEntries: 32768, maxDirectoryBytes: 16 * 1024 * 1024 });
  if (!index) throw new BadRequestException('The EPUB archive exceeds supported mapping limits or cannot be read');
  return openZipFileWithOptions(filePath, { tailSize: 65535 + 22 });
}

export async function readBoundedEpubEntry(entry: unzipper.File, maximumBytes = 8 * 1024 * 1024): Promise<Buffer> {
  if (entry.uncompressedSize > maximumBytes) throw new BadRequestException('The EPUB entry exceeds the supported mapping limit');
  const stream = entry.stream();
  const chunks: Buffer[] = [];
  let size = 0;
  try {
    for await (const value of stream) {
      const chunk = Buffer.isBuffer(value) ? value : Buffer.from(value);
      size += chunk.length;
      if (size > maximumBytes) throw new BadRequestException('The EPUB entry exceeds the supported mapping limit');
      chunks.push(chunk);
    }
    return Buffer.concat(chunks, size);
  } finally {
    stream.destroy();
  }
}
