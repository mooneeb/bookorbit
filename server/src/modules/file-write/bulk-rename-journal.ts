import { BadRequestException } from '@nestjs/common';
import type { Stats } from 'fs';
import { link, lstat, mkdir, readFile, realpath, rename, rm, unlink, writeFile } from 'fs/promises';
import { dirname, isAbsolute, join, relative, sep } from 'path';

import type { BookFilePathUpdate, FileRenameRepository } from './file-rename.repository';

interface RenameIntent {
  bookId: number;
  libraryId: number;
  folderPath: string;
  files: { id: number; from: string; to: string; dev: number; ino: number; size: number; mtimeMs: number }[];
}

export class BulkRenameJournal {
  constructor(
    private readonly directory: string,
    private readonly repo: FileRenameRepository,
  ) {}

  private path(bookId: number): string {
    return join(this.directory, `${bookId}.json`);
  }

  async recover(bookId: number, libraryId: number, libraryRoot: string): Promise<boolean> {
    let raw: string;
    try {
      raw = await readFile(this.path(bookId), 'utf8');
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code === 'ENOENT') return false;
      throw error;
    }
    const intent = JSON.parse(raw) as RenameIntent;
    if (intent.bookId !== bookId || intent.libraryId !== libraryId) throw new BadRequestException('Rename recovery belongs to another library.');
    await this.apply(intent, libraryRoot);
    return true;
  }

  async move(
    bookId: number,
    libraryId: number,
    libraryRoot: string,
    folderPath: string,
    files: { id: number; absolutePath: string }[],
    targets: Map<number, string>,
  ): Promise<void> {
    const intent: RenameIntent = { bookId, libraryId, folderPath, files: [] };
    for (const file of files) {
      const fingerprint = await lstat(file.absolutePath);
      if (!fingerprint.isFile()) throw new BadRequestException('Only regular book files can be renamed.');
      intent.files.push({
        id: file.id,
        from: file.absolutePath,
        to: targets.get(file.id)!,
        dev: fingerprint.dev,
        ino: fingerprint.ino,
        size: fingerprint.size,
        mtimeMs: fingerprint.mtimeMs,
      });
    }
    await mkdir(this.directory, { recursive: true });
    const path = this.path(bookId);
    await writeFile(`${path}.tmp`, JSON.stringify(intent), { mode: 0o600 });
    await rename(`${path}.tmp`, path);
    await this.apply(intent, libraryRoot);
  }

  private async apply(intent: RenameIntent, libraryRoot: string): Promise<void> {
    const realRoot = await realpath(libraryRoot);
    for (const file of intent.files) {
      for (const path of [file.from, file.to]) {
        const rel = relative(libraryRoot, path);
        if (!rel || rel === '..' || rel.startsWith(`..${sep}`) || isAbsolute(rel))
          throw new BadRequestException('Rename path is outside the library folder.');
        await this.checkParent(path, realRoot);
      }
      if (file.from === file.to) continue;
      const source = await this.fingerprint(file.from);
      const target = await this.fingerprint(file.to);
      if (source && !this.matches(source, file)) throw new BadRequestException('Source file changed since rename started.');
      if (target && !this.matches(target, file)) throw new BadRequestException('Target file already exists or changed since rename started.');
      if (!source && !target) throw new BadRequestException('Rename source file is missing.');
      if (source && target && (await realpath(file.from)) === (await realpath(file.to))) {
        await rename(file.from, file.to);
        continue;
      }
      if (!target) {
        await mkdir(dirname(file.to), { recursive: true });
        // Creating a hard link is exclusive, so a concurrently-created target is never replaced.
        await link(file.from, file.to);
      }
      if (source) await unlink(file.from);
    }
    const updates: BookFilePathUpdate[] = intent.files.map((file) => ({
      id: file.id,
      absolutePath: file.to,
      relPath: relative(libraryRoot, file.to),
    }));
    await this.repo.applyFolderRename(intent.bookId, updates, intent.folderPath);
    await rm(this.path(intent.bookId), { force: true });
  }

  private async checkParent(path: string, realRoot: string): Promise<void> {
    let parent = dirname(path);
    while (true) {
      try {
        const actual = await realpath(parent);
        const rel = relative(realRoot, actual);
        if (rel === '..' || rel.startsWith(`..${sep}`) || isAbsolute(rel))
          throw new BadRequestException('Rename path resolves outside the library folder.');
        return;
      } catch (error) {
        if ((error as NodeJS.ErrnoException).code !== 'ENOENT') throw error;
        const next = dirname(parent);
        if (next === parent) throw error;
        parent = next;
      }
    }
  }

  private async fingerprint(path: string): Promise<Stats | null> {
    try {
      const info = await lstat(path);
      if (!info.isFile()) throw new BadRequestException('Only regular book files can be renamed.');
      return info;
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code === 'ENOENT') return null;
      throw error;
    }
  }

  private matches(actual: Stats, expected: RenameIntent['files'][number]): boolean {
    return actual.dev === expected.dev && actual.ino === expected.ino && actual.size === expected.size && actual.mtimeMs === expected.mtimeMs;
  }
}
