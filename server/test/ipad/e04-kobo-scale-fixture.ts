import { link, mkdir, stat } from 'node:fs/promises';
import { dirname, join } from 'node:path';
import { and, asc, eq, gt, isNull, like, lte, sql } from 'drizzle-orm';
import type { NodePgDatabase } from 'drizzle-orm/node-postgres';

import * as schema from '../../src/db/schema';
import { mapWithConcurrency } from '../../src/common/utils/batch.utils';

export async function createE04KoboScaleFixture(db: NodePgDatabase<typeof schema>) {
  const [source] = await db
    .select()
    .from(schema.bookFiles)
    .where(and(eq(schema.bookFiles.bookId, 2), eq(schema.bookFiles.format, 'epub')))
    .limit(1);
  if (!source) throw new Error('Kobo scale fixture requires the existing real EPUB fixture');
  const sourceInfo = await stat(source.absolutePath, { bigint: true });
  const folder = join(dirname(source.absolutePath), 'kobo-scale');
  await mkdir(folder, { recursive: true });
  let afterBookId = 10;
  let eligibleCount = 0;
  let firstBookId = 0;
  for (;;) {
    const books = await db
      .select({ id: schema.books.id, libraryFolderId: schema.books.libraryFolderId })
      .from(schema.books)
      .innerJoin(schema.bookMetadata, eq(schema.bookMetadata.bookId, schema.books.id))
      .where(
        and(
          gt(schema.books.id, afterBookId),
          lte(schema.books.id, 50_000),
          isNull(schema.books.primaryFileId),
          like(schema.bookMetadata.title, 'Library book%'),
        ),
      )
      .orderBy(asc(schema.books.id))
      .limit(500);
    if (!books.length) break;
    const paths = await mapWithConcurrency(books, 8, async ({ id }) => {
      const path = join(folder, `${id}.epub`);
      await link(source.absolutePath, path).catch((error: unknown) => {
        if ((error as NodeJS.ErrnoException).code !== 'EEXIST') throw error;
      });
      return path;
    });
    const files = await db
      .insert(schema.bookFiles)
      .values(
        books.map(({ id, libraryFolderId }, index) => ({
          bookId: id,
          libraryFolderId,
          ino: sourceInfo.ino,
          absolutePath: paths[index],
          format: 'epub',
          sizeBytes: source.sizeBytes,
          fileHash: source.fileHash,
          isFixedLayout: false,
          mediaOverlayAvailable: false,
        })),
      )
      .onConflictDoUpdate({ target: schema.bookFiles.absolutePath, set: { isFixedLayout: false } })
      .returning({ id: schema.bookFiles.id, bookId: schema.bookFiles.bookId });
    const values = sql.join(
      files.map((file) => sql`(${file.bookId}::integer, ${file.id}::integer)`),
      sql`, `,
    );
    await db.execute(sql`
      UPDATE ${schema.books} AS book SET primary_file_id = file.id
      FROM (VALUES ${values}) AS file(book_id, id)
      WHERE book.id = file.book_id AND book.primary_file_id IS NULL
    `);
    firstBookId ||= books[0]!.id;
    afterBookId = books[books.length - 1]!.id;
    eligibleCount += books.length;
  }
  const [total] = await db
    .select({ count: sql<number>`count(*)::integer`, first: sql<number>`min(${schema.books.id})`, last: sql<number>`max(${schema.books.id})` })
    .from(schema.books)
    .innerJoin(schema.bookFiles, eq(schema.bookFiles.id, schema.books.primaryFileId))
    .innerJoin(schema.bookMetadata, eq(schema.bookMetadata.bookId, schema.books.id))
    .where(
      and(
        gt(schema.books.id, 10),
        lte(schema.books.id, 50_000),
        like(schema.bookMetadata.title, 'Library book%'),
        eq(schema.bookFiles.format, 'epub'),
      ),
    );
  eligibleCount = total?.count ?? 0;
  firstBookId = total?.first ?? firstBookId;
  afterBookId = total?.last ?? afterBookId;
  if (eligibleCount < 49_000) throw new Error(`Kobo scale fixture expected the 50,000-book library, seeded ${eligibleCount}`);
  return { firstBookId, lastBookId: afterBookId, eligibleCount, sourceBookFileId: source.id, scopeTitlePrefix: 'Library book' };
}
