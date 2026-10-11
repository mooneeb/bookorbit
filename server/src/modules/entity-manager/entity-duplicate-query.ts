import { sql, type SQL } from 'drizzle-orm';
import type { NodePgDatabase } from 'drizzle-orm/node-postgres';
import type { EntityType, FirstClassEntityType } from '@bookorbit/types';
import { buildContentFilterClauses } from '../../common/utils/content-filter-sql.utils';
import * as schema from '../../db/schema';
import { books } from '../../db/schema';
import type { EntityBookScope } from './strategies/entity-strategy.interface';

export const ENTITY_DUPLICATE_TABLES: Record<FirstClassEntityType, { table: string; relation: string; column: string }> = {
  author: { table: 'authors', relation: 'book_authors', column: 'author_id' },
  genre: { table: 'genres', relation: 'book_genres', column: 'genre_id' },
  tag: { table: 'tags', relation: 'book_tags', column: 'tag_id' },
  narrator: { table: 'narrators', relation: 'book_narrators', column: 'narrator_id' },
  series: { table: 'book_series', relation: 'book_series_memberships', column: 'series_id' },
};

export function scopedBookCondition(db: NodePgDatabase<typeof schema>, scope: EntityBookScope): SQL {
  if (scope.libraryIds.length === 0) return sql`false`;
  return sql.join(
    [
      sql`${books.libraryId} IN (${sql.join(
        scope.libraryIds.map((id) => sql`${id}`),
        sql`, `,
      )})`,
      ...(scope.contentFilters ? buildContentFilterClauses(scope.contentFilters, db) : []),
    ],
    sql` AND `,
  );
}

export function scopedEntityCondition(db: NodePgDatabase<typeof schema>, entityType: EntityType, identity: SQL, scope: EntityBookScope): SQL {
  const condition = scopedBookCondition(db, scope);
  if (entityType === 'publisher' || entityType === 'language') {
    return sql`EXISTS (SELECT 1 FROM book_metadata scoped_relation JOIN ${books} ON scoped_relation.book_id = ${books.id}
      WHERE ${sql.raw(`scoped_relation.${entityType}`)} = ${identity} AND ${condition})`;
  }
  const relation = ENTITY_DUPLICATE_TABLES[entityType];
  return sql`EXISTS (SELECT 1 FROM ${sql.raw(relation.relation)} scoped_relation JOIN ${books} ON scoped_relation.book_id = ${books.id}
    WHERE ${sql.raw(`scoped_relation.${relation.column}`)} = ${identity} AND ${condition})`;
}
