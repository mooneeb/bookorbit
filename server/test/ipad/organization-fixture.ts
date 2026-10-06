import type { NodePgDatabase } from 'drizzle-orm/node-postgres';

import * as schema from '../../src/db/schema';

export async function createOrganizationFixture(db: NodePgDatabase<typeof schema>) {
  const authors = await db
    .insert(schema.authors)
    .values(
      Array.from({ length: 55 }, (_, index) => ({
        name: `Orbit author ${String(index).padStart(3, '0')}`,
        sortName: index === 0 ? 'Author, Orbit' : null,
        description: index === 0 ? 'An author profile for the native organization journey.' : null,
        birthYear: index === 0 ? 1975 : null,
        genres: index === 0 ? ['Science fiction'] : null,
        influences: index === 0 ? ['Orbit predecessor'] : null,
      })),
    )
    .returning({ id: schema.authors.id });
  await db.insert(schema.bookAuthors).values(
    authors.flatMap((author, index) =>
      (index === 0 ? [1, ...Array.from({ length: 44 }, (_, offset) => 201 + offset)] : [100 + index]).map((bookId) => ({
        bookId,
        authorId: author.id,
      })),
    ),
  );
  const series = await db
    .insert(schema.bookSeries)
    .values(
      Array.from({ length: 55 }, (_, index) => ({
        name: `Orbit series ${String(index).padStart(3, '0')}`,
        normalizedName: `orbit series ${String(index).padStart(3, '0')}`,
        expectedBookCount: index === 0 ? 47 : 1,
      })),
    )
    .returning({ id: schema.bookSeries.id });
  await db.insert(schema.bookSeriesMemberships).values(
    series.flatMap((item, index) =>
      (index === 0 ? [1, ...Array.from({ length: 44 }, (_, offset) => 201 + offset)] : [100 + index]).map((bookId, offset) => ({
        bookId,
        seriesId: item.id,
        seriesIndex: String(offset === 0 ? 1 : offset + 2),
      })),
    ),
  );
}
