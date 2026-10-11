import { Test } from '@nestjs/testing';
import { mkdtemp, readFile, stat, writeFile, rm } from 'fs/promises';
import { join } from 'path';
import { tmpdir } from 'os';
import { BookDockPublicationService } from './book-dock-publication.service';

describe('Book Dock file publication', () => {
  let root: string;
  beforeEach(async () => {
    root = await mkdtemp(join(tmpdir(), 'bookorbit-dock-publication-'));
  });
  afterEach(async () => {
    await rm(root, { recursive: true, force: true });
  });
  it('recovers a published file without overwriting another file or removing its source', async () => {
    const module = await Test.createTestingModule({ providers: [BookDockPublicationService] }).compile();
    const publisher = module.get(BookDockPublicationService);
    const sourcePath = join(root, 'source.pdf');
    const destPath = join(root, 'library', 'book.pdf');
    await writeFile(sourcePath, 'source bytes');
    const plan = await publisher.prepare([{ sourcePath, destPath }], root, 17);
    await publisher.publish(plan, root);
    await publisher.publish(plan, root);
    expect(await readFile(destPath, 'utf8')).toBe('source bytes');
    expect(await readFile(sourcePath, 'utf8')).toBe('source bytes');
    expect((await stat(plan[0]!.stagingPath)).ino).toBe((await stat(destPath)).ino);
    const otherSource = join(root, 'other.pdf');
    await writeFile(otherSource, 'source bytes');
    const other = await publisher.prepare([{ sourcePath: otherSource, destPath }], root, 18);
    await expect(publisher.publish(other, root)).rejects.toThrow('already exists');
    expect(await readFile(destPath, 'utf8')).toBe('source bytes');
    await module.close();
  });
});
