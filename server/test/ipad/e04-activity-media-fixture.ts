import assert from 'node:assert/strict';
import { stat } from 'node:fs/promises';
import { dirname, isAbsolute, join, relative, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { and, eq } from 'drizzle-orm';
import type { NodePgDatabase } from 'drizzle-orm/node-postgres';

import * as schema from '../../src/db/schema';

export async function ensureE04ActivityMediaFixture(
  db: NodePgDatabase<typeof schema>,
  input: { contentDirectory: string; libraryId: number; libraryFolderId: number },
) {
  assert.ok(Number.isSafeInteger(input.libraryId) && input.libraryId > 0);
  assert.ok(Number.isSafeInteger(input.libraryFolderId) && input.libraryFolderId > 0);
  const [libraryFolder] = await db
    .select({ path: schema.libraryFolders.path })
    .from(schema.libraryFolders)
    .where(and(eq(schema.libraryFolders.id, input.libraryFolderId), eq(schema.libraryFolders.libraryId, input.libraryId)))
    .limit(1);
  assert.ok(libraryFolder, 'Activity media requires the retained fixture library folder');
  const contentDirectory = resolve(input.contentDirectory);
  const contained = relative(resolve(libraryFolder.path), contentDirectory);
  assert.ok(
    !isAbsolute(contained) && contained !== '..' && !contained.startsWith('../'),
    'Activity media must stay inside its owning library folder',
  );
  const repositoryRoot = process.env.IPAD_HARNESS_REPOSITORY_ROOT;
  assert.ok(repositoryRoot && isAbsolute(repositoryRoot), 'Activity media requires the absolute harness repository root');
  const generatorURL = pathToFileURL(resolve(repositoryRoot, 'scripts/ipad/activity-media-fixture.mjs')).href;
  const {
    ensureActivityMediaFixture,
  }: typeof import('../../../scripts/ipad/activity-media-fixture.mjs', {
    with: { 'resolution-mode': 'import' },
  }) = await import(generatorURL);
  const media = await ensureActivityMediaFixture(join(contentDirectory, 'e04-activity-media'));
  const entries = [
    { path: media.audioPath, title: media.audioTitle, format: 'm4a', duration: media.audioDurationSeconds, narrated: false },
    { path: media.epubPath, title: media.epubTitle, format: 'epub', duration: media.narrationDurationSeconds, narrated: true },
  ];
  const files = await Promise.all(entries.map(async (entry) => ({ ...entry, info: await stat(entry.path) })));
  const result = await db.transaction(async (transaction) => {
    const ids: { bookId: number; fileId: number }[] = [];
    for (const entry of files) {
      const folderPath = dirname(entry.path);
      await transaction
        .insert(schema.books)
        .values({ libraryId: input.libraryId, libraryFolderId: input.libraryFolderId, folderPath, status: 'present' })
        .onConflictDoNothing({ target: [schema.books.libraryId, schema.books.folderPath] });
      const [book] = await transaction
        .select({ id: schema.books.id, libraryFolderId: schema.books.libraryFolderId, primaryFileId: schema.books.primaryFileId })
        .from(schema.books)
        .where(and(eq(schema.books.libraryId, input.libraryId), eq(schema.books.folderPath, folderPath)))
        .limit(1);
      assert.ok(book && book.libraryFolderId === input.libraryFolderId, 'An activity book must belong to its fixture library folder');
      await transaction
        .insert(schema.bookFiles)
        .values({
          bookId: book.id,
          libraryFolderId: input.libraryFolderId,
          absolutePath: entry.path,
          relPath: relative(resolve(libraryFolder.path), entry.path),
          ino: BigInt(entry.info.ino),
          sizeBytes: entry.info.size,
          mtime: entry.info.mtime,
          format: entry.format,
          role: 'content',
          durationSeconds: entry.narrated ? null : Math.round(entry.duration),
          mediaOverlayAvailable: entry.narrated,
          mediaOverlayDurationSeconds: entry.narrated ? entry.duration : null,
          mediaOverlayCheckedAt: entry.narrated ? new Date() : null,
        })
        .onConflictDoNothing({ target: schema.bookFiles.absolutePath });
      const [file] = await transaction
        .select({
          id: schema.bookFiles.id,
          bookId: schema.bookFiles.bookId,
          libraryFolderId: schema.bookFiles.libraryFolderId,
          format: schema.bookFiles.format,
        })
        .from(schema.bookFiles)
        .where(eq(schema.bookFiles.absolutePath, entry.path))
        .limit(1);
      assert.ok(file && file.bookId === book.id && file.libraryFolderId === input.libraryFolderId && file.format === entry.format);
      assert.ok(book.primaryFileId === null || book.primaryFileId === file.id, 'An activity fixture must not replace another primary file');
      if (book.primaryFileId === null) await transaction.update(schema.books).set({ primaryFileId: file.id }).where(eq(schema.books.id, book.id));
      await transaction
        .insert(schema.bookMetadata)
        .values({
          bookId: book.id,
          title: entry.title,
          language: 'en',
          description: 'An original locally recorded sixty-second passage for native activity interruption acceptance.',
          durationSeconds: entry.narrated ? null : Math.round(entry.duration),
        })
        .onConflictDoNothing({ target: schema.bookMetadata.bookId });
      const [metadata] = await transaction
        .select({ title: schema.bookMetadata.title })
        .from(schema.bookMetadata)
        .where(eq(schema.bookMetadata.bookId, book.id))
        .limit(1);
      assert.equal(metadata?.title, entry.title, 'An activity fixture must not overwrite retained book metadata');
      ids.push({ bookId: book.id, fileId: file.id });
    }
    return ids;
  });
  return {
    audioBookId: result[0].bookId,
    audioFileId: result[0].fileId,
    epubBookId: result[1].bookId,
    epubFileId: result[1].fileId,
    audioDurationSeconds: media.audioDurationSeconds,
    narrationDurationSeconds: media.narrationDurationSeconds,
  };
}
