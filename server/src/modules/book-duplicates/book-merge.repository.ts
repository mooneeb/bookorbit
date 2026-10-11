import { createHash } from 'node:crypto';
import { ConflictException, Inject, Injectable, NotFoundException } from '@nestjs/common';
import { and, eq, getTableColumns, inArray, sql } from 'drizzle-orm';
import type { NodePgDatabase } from 'drizzle-orm/node-postgres';
import { AUDIO_FORMAT_LIST, type MergeBooksPreview, type MergeBooksRequest, type MergeBooksResult } from '@bookorbit/types';
import type { RequestUser } from '../../common/types/request-user';
import { DB } from '../../db';
import { deleteBooksWithHashInvalidation } from '../../db/book-file-hash-history';
import * as schema from '../../db/schema';
import type { BookMergeCoverIntent } from './book-merge-cover.service';

export interface BookMergeReceipt {
  result: MergeBooksResult;
  preservationIntent: BookMergeCoverIntent;
  preservationComplete: boolean;
}

const RECEIPT_ACTION = 'book.duplicate_merge';
const MAX_RELATED_ROWS = 100_000;
const UNION_KEYS: Record<string, string[]> = {
  book_authors: ['author_id'],
  book_genres: ['genre_id'],
  book_tags: ['tag_id'],
  book_narrators: ['narrator_id'],
  collection_books: ['collection_id'],
  book_series_memberships: ['series_id'],
};
const STATE_KEYS: Record<string, string[]> = {
  kobo_snapshot_books: ['snapshot_id'],
  kobo_device_snapshot_books: ['snapshot_id'],
  kobo_book_entitlements: ['user_id'],
  kobo_reading_states: ['user_id'],
  user_book_status: ['user_id'],
  user_book_ratings: ['user_id'],
  user_book_notes: ['user_id'],
  audiobook_progress: ['user_id'],
  user_book_read_aloud_sync_settings: ['user_id'],
  book_custom_metadata_values: ['field_id'],
  book_community_ratings: ['provider'],
  comic_metadata: [],
  tts_book_preferences: ['user_id'],
  hardcover_book_state: ['user_id'],
  storygraph_book_state: ['user_id'],
  reading_session_sync_cursors: ['user_id', 'source', 'source_device_key'],
};
const DIRECT_TABLES = new Set([
  'book_files',
  'reading_attempts',
  'reading_sessions',
  'reading_session_deletions',
  'book_journal_entries',
  'annotations',
  'bookmarks',
  'native_annotation_drafts',
  'file_write_log',
  'email_send_log',
  'book_requests',
  'upload_sessions',
]);
const RECOMPUTABLE_TABLES = new Set([
  'book_duplicate_scan_keys',
  'book_duplicate_groups',
  'book_duplicate_dismissals',
  'book_duplicate_pairs',
  'book_duplicate_group_members',
]);
const METADATA_IGNORED = [
  'book_id',
  'updated_at',
  'metadata_score',
  'last_metadata_fetch_at',
  'last_written_at',
  'embedding',
  'cover_updated_at',
  'cover_source',
  'locked_fields',
];

@Injectable()
export class BookMergeRepository {
  constructor(@Inject(DB) private readonly db: NodePgDatabase<typeof schema>) {}

  async receipt(dto: MergeBooksRequest, userId: number): Promise<BookMergeReceipt | null> {
    const [row] = await this.db
      .select({ meta: schema.auditLog.meta })
      .from(schema.auditLog)
      .where(and(eq(schema.auditLog.action, RECEIPT_ACTION), eq(schema.auditLog.resourceId, dto.sourceBookId), eq(schema.auditLog.userId, userId)))
      .orderBy(sql`${schema.auditLog.id} desc`)
      .limit(1);
    const meta = row?.meta as ({ previewToken: string } & BookMergeReceipt) | undefined;
    if (!meta?.result) return null;
    if (meta.result.targetBookId !== dto.targetBookId || meta.previewToken !== dto.previewToken) {
      throw new ConflictException('This source book was already merged using a different preview');
    }
    return {
      result: { ...meta.result, alreadyApplied: true },
      preservationIntent: meta.preservationIntent,
      preservationComplete: meta.preservationComplete,
    };
  }

  async markPreservationComplete(dto: MergeBooksRequest, userId: number): Promise<void> {
    await this.db.execute(sql`update ${schema.auditLog} set meta=jsonb_set(meta,'{preservationComplete}','true'::jsonb)
      where user_id=${userId} and action=${RECEIPT_ACTION} and resource_id=${dto.sourceBookId}
        and meta->>'previewToken'=${dto.previewToken} and meta->'result'->>'targetBookId'=${String(dto.targetBookId)}`);
  }

  async preview(dto: MergeBooksRequest, user: RequestUser, preservationIntent: BookMergeCoverIntent): Promise<MergeBooksPreview> {
    return this.run(dto, user, false, preservationIntent) as Promise<MergeBooksPreview>;
  }

  async apply(dto: MergeBooksRequest, user: RequestUser, preservationIntent: BookMergeCoverIntent): Promise<MergeBooksResult> {
    return this.run(dto, user, true, preservationIntent) as Promise<MergeBooksResult>;
  }

  private async run(
    dto: MergeBooksRequest,
    user: RequestUser,
    apply: boolean,
    preservationIntent: BookMergeCoverIntent,
  ): Promise<MergeBooksPreview | MergeBooksResult> {
    return this.db.transaction(async (tx) => {
      const pair = [dto.sourceBookId, dto.targetBookId].sort((a, b) => a - b);
      for (const id of pair) await tx.execute(sql`select pg_advisory_xact_lock(7304, ${id})`);
      const rows = await tx.select().from(schema.books).where(inArray(schema.books.id, pair)).orderBy(schema.books.id).for('update');
      const source = rows.find((row) => row.id === dto.sourceBookId);
      const target = rows.find((row) => row.id === dto.targetBookId);
      if (!source || !target) {
        if (apply && target) {
          const result = await this.receipt(dto, user.id);
          if (result) return result.result;
        }
        throw new NotFoundException('Selected book no longer exists');
      }
      const blockers: string[] = [];
      if (source.libraryId !== target.libraryId || source.libraryFolderId !== target.libraryFolderId) {
        blockers.push('Books must belong to the same library folder to preserve their file paths');
      }
      if (source.status !== 'present' || target.status !== 'present') blockers.push('Both books must be present and finish processing first');
      const references = (
        await tx.execute<{ table_name: string; column_name: string }>(sql`
        select distinct c.relname as table_name, a.attname as column_name
        from pg_constraint fk join pg_class c on c.oid = fk.conrelid
        join pg_namespace n on n.oid = c.relnamespace
        join lateral unnest(fk.conkey) with ordinality k(attnum, ordinal) on true
        join lateral unnest(fk.confkey) with ordinality r(attnum, ordinal) on r.ordinal = k.ordinal
        join pg_attribute a on a.attrelid = c.oid and a.attnum = k.attnum
        join pg_attribute b on b.attrelid = fk.confrelid and b.attnum = r.attnum
        where fk.contype = 'f' and fk.confrelid = 'books'::regclass and b.attname = 'id' and n.nspname = 'public'
        order by c.relname, a.attname
      `)
      ).rows;
      const hashes: string[] = [JSON.stringify(rows), preservationIntent.sourceFingerprint];
      let relatedRows = 0;
      for (const ref of references) {
        const table = sql.identifier(ref.table_name);
        const column = sql.identifier(ref.column_name);
        const [size] = (
          await tx.execute<{ count: number }>(sql`select count(*)::integer as count from
          (select 1 from ${table} where ${column} in (${source.id}, ${target.id}) limit ${MAX_RELATED_ROWS + 1}) bounded`)
        ).rows;
        relatedRows += size.count;
        if (relatedRows > MAX_RELATED_ROWS) {
          if (apply) throw new ConflictException('This pair exceeds 100000 related records; review its history separately before merging');
          return {
            sourceBookId: source.id,
            targetBookId: target.id,
            previewToken: createHash('sha256').update(`${user.id}:${source.id}:${target.id}:over-limit`).digest('hex'),
            filesPreserved: 0,
            canApply: false,
            warnings: [],
            blockers: ['This pair exceeds 100000 related records; review its history separately before merging'],
          };
        }
        await tx.execute(
          sql`with locked as (select 1 from ${table} where ${column} in (${source.id}, ${target.id}) for update) select count(*) from locked`,
        );
        const [fingerprint] = (
          await tx.execute<{ count: string; digest: string; source_count: string }>(sql`
          select count(*)::text as count, count(*) filter (where ${column} = ${source.id})::text as source_count,
            md5(coalesce(string_agg(digest, '' order by digest), '')) as digest
          from (select ${column}, md5(to_jsonb(r)::text) as digest from ${table} r where ${column} in (${source.id}, ${target.id})) states
        `)
        ).rows;
        hashes.push(`${ref.table_name}:${ref.column_name}:${fingerprint.digest}`);
        if (!Number(fingerprint.source_count) || RECOMPUTABLE_TABLES.has(ref.table_name)) continue;
        if (ref.table_name === 'book_metadata') {
          const [conflict] = (
            await tx.execute<{ fields: string[] | null }>(sql`
            select array_agg(s.key order by s.key) as fields
            from book_metadata source join book_metadata target on target.book_id = ${target.id},
              lateral jsonb_each(to_jsonb(source.*) - ${sql.param(METADATA_IGNORED)}::text[]) s
            where source.book_id = ${source.id} and s.value <> 'null'::jsonb
              and to_jsonb(target.*)->s.key <> 'null'::jsonb and s.value <> to_jsonb(target.*)->s.key
          `)
          ).rows;
          if (conflict.fields?.length) blockers.push(`Resolve conflicting metadata first: ${conflict.fields.join(', ')}`);
          continue;
        }
        if (ref.table_name === 'native_annotation_acks' || ref.table_name === 'book_covers') continue;
        const keys = STATE_KEYS[ref.table_name] ?? UNION_KEYS[ref.table_name];
        if (keys) {
          const joins = sql.join(
            keys.map((key) => sql`source.${sql.identifier(key)} is not distinct from target.${sql.identifier(key)}`),
            sql` and `,
          );
          const ignored = ['book_id', 'id', 'created_at', 'updated_at', ...(UNION_KEYS[ref.table_name] ? ['display_order'] : [])];
          const [conflict] = (
            await tx.execute<{ conflict: boolean }>(sql`
            select exists(select 1 from ${table} source join ${table} target on ${keys.length ? joins : sql`true`}
              where source.${column} = ${source.id} and target.${column} = ${target.id}
                and (to_jsonb(source.*) - ${sql.param(ignored)}::text[]) <> (to_jsonb(target.*) - ${sql.param(ignored)}::text[])) as conflict
          `)
          ).rows;
          if (conflict.conflict) blockers.push(`Resolve conflicting ${ref.table_name.replaceAll('_', ' ')} first`);
        } else if (!DIRECT_TABLES.has(ref.table_name)) {
          blockers.push(`This book has ${ref.table_name.replaceAll('_', ' ')} that require separate review before merging`);
        }
      }
      const [unsafe] = (
        await tx.execute<{
          active: boolean;
          bookmarks: boolean;
          annotations: boolean;
          pending: boolean;
          unpublished_ink: boolean;
          conflicting_audio: boolean;
          source_kobo: boolean;
          target_kobo: boolean;
          legacy_kobo: boolean;
        }>(sql`
        select
          exists(select 1 from reading_attempts s join reading_attempts t on s.user_id=t.user_id where s.book_id=${source.id} and t.book_id=${target.id} and s.outcome is null and t.outcome is null and s.deleted_at is null and t.deleted_at is null) as active,
          exists(select 1 from bookmarks s join bookmarks t on s.user_id=t.user_id where s.book_id=${source.id} and t.book_id=${target.id} and (
            s.client_id=t.client_id or (s.deleted_at is null and t.deleted_at is null and (s.cfi=t.cfi or (s.cfi is null and t.cfi is null and s.position_seconds=t.position_seconds))))) as bookmarks,
          exists(select 1 from annotations s join annotations t on s.user_id=t.user_id and s.client_id=t.client_id where s.book_id=${source.id} and t.book_id=${target.id}) as annotations,
          exists(select 1 from upload_sessions where target_book_id in (${source.id},${target.id}) and status not in ('completed','cancelled','failed','expired')) as pending,
          exists(select 1 from book_files where book_id=${source.id} and role='content' and lower(format)=any(${sql.param(AUDIO_FORMAT_LIST)}::text[]))
            and exists(select 1 from book_files where book_id=${target.id} and role='content' and lower(format)=any(${sql.param(AUDIO_FORMAT_LIST)}::text[])) as conflicting_audio,
          exists(select 1 from annotations ink where ink.book_id=${source.id} and ink.kind='pdf_ink' and not exists(
            select 1 from native_annotation_operations published
            where published.result->>'status'='applied' and published.result->'annotation'->>'kind'='pdf_ink'
              and published.result->'annotation'->>'clientId'=ink.client_id::text
              and published.result->'annotation'->>'id'=ink.id::text
              and (published.result->'annotation'->>'version')::integer=ink.version
              and published.result->'publication'->>'status'='published'
          )) as unpublished_ink,
          exists(select 1 from kobo_book_entitlements where book_id=${source.id}
            union all select 1 from kobo_reading_states where book_id=${source.id}
            union all select 1 from kobo_device_snapshot_books where book_id=${source.id}
            union all select 1 from kobo_snapshot_books where book_id=${source.id}) as source_kobo,
          exists(select 1 from kobo_book_entitlements where book_id=${target.id}
            union all select 1 from kobo_reading_states where book_id=${target.id}
            union all select 1 from kobo_device_snapshot_books where book_id=${target.id}
            union all select 1 from kobo_snapshot_books where book_id=${target.id}) as target_kobo,
          exists(select 1 from kobo_reading_states where book_id=${source.id} and entitlement_id ~ '^[0-9]+$'
            union all select 1 from kobo_device_snapshot_books where book_id=${source.id} and needs_legacy_numeric_removal=true
            union all select 1 from kobo_book_entitlements where book_id=${source.id} and needs_legacy_numeric_removal=true
            union all select 1 from kobo_snapshot_books where book_id=${source.id} and (synced=true or pending_delete=true or removed_by_device=true)) as legacy_kobo
      `)
      ).rows;
      if (unsafe.active) blockers.push('Both books have an active reading attempt for the same reader');
      if (unsafe.bookmarks || unsafe.annotations) blockers.push('Reader item identities or bookmark locations conflict; resolve them before merging');
      if (unsafe.pending) blockers.push('Finish or cancel active uploads before merging');
      if (unsafe.conflicting_audio)
        blockers.push('Both books contain distinct audio timelines; keep their recordings separate to preserve audio reading positions');
      if (unsafe.unpublished_ink) blockers.push('Publish or recover pending source PDF ink before merging');
      if (unsafe.legacy_kobo) blockers.push('Finish legacy Kobo identity migration before merging this book');
      if (unsafe.source_kobo && !source.primaryFileId) blockers.push('Restore the source primary file before merging its Kobo reading state');
      if (unsafe.source_kobo && unsafe.target_kobo && source.primaryFileId !== target.primaryFileId) {
        blockers.push('Both books have Kobo deliveries tied to different main files; choose a pair without conflicting deliveries');
      }
      const primaryFileId = unsafe.source_kobo ? source.primaryFileId : (target.primaryFileId ?? source.primaryFileId);
      const [passageBookmarks] = (
        await tx.execute<{ unsafe: boolean }>(sql`
        select exists(select 1 from bookmarks bookmark join books book on book.id=bookmark.book_id
          where book.id in (${source.id},${target.id}) and bookmark.cfi is not null and bookmark.deleted_at is null
            and book.primary_file_id is distinct from ${primaryFileId}::integer) as unsafe
      `)
      ).rows;
      if (passageBookmarks.unsafe)
        blockers.push('Passage bookmarks are tied to a different main file; keep these books separate to preserve their reading positions');
      const [metadataCount] = await tx
        .select({ count: sql<number>`count(*)::integer` })
        .from(schema.bookMetadata)
        .where(inArray(schema.bookMetadata.bookId, pair));
      if (metadataCount.count !== 2) blockers.push('Both books need metadata records before merging');
      const [files] = await tx
        .select({ count: sql<number>`count(*)::integer` })
        .from(schema.bookFiles)
        .where(inArray(schema.bookFiles.bookId, pair));
      const preview: MergeBooksPreview = {
        sourceBookId: source.id,
        targetBookId: target.id,
        previewToken: createHash('sha256')
          .update(`${user.id}:${source.id}:${target.id}:${hashes.join('|')}`)
          .digest('hex'),
        filesPreserved: files.count,
        canApply: blockers.length === 0,
        blockers,
        warnings:
          unsafe.source_kobo && source.primaryFileId !== target.primaryFileId
            ? ["The source book's main file will remain primary to preserve Kobo reading state."]
            : [],
      };
      if (!apply) return preview;
      if (!dto.previewToken || dto.previewToken !== preview.previewToken)
        throw new ConflictException('Books changed since preview; review a new preview before merging');
      if (blockers.length) throw new ConflictException(blockers.join('; '));
      // Legacy passage anchors otherwise follow the keeper's primary file after transfer or Kobo promotion.
      await tx.execute(sql`
        with legacy_positions as (
          select position.id, coalesce(
            (select bound.book_file_id from annotation_positions bound
              where bound.annotation_id=annotation.id and bound.user_id=annotation.user_id
                and bound.format in ('xpointer','pdf') and bound.book_file_id is not null limit 1),
            book.primary_file_id
          ) as file_id
          from annotation_positions position join annotations annotation on annotation.id=position.annotation_id
            and annotation.user_id=position.user_id
          join books book on book.id=annotation.book_id
          where book.id in (${source.id},${target.id}) and position.book_file_id is null
        )
        update annotation_positions position set book_file_id=legacy.file_id
        from legacy_positions legacy where position.id=legacy.id and position.book_file_id is null and legacy.file_id is not null
      `);
      const sourceFiles = await tx.select({ id: schema.bookFiles.id }).from(schema.bookFiles).where(eq(schema.bookFiles.bookId, source.id));
      for (const ref of references) {
        if (
          RECOMPUTABLE_TABLES.has(ref.table_name) ||
          ref.table_name === 'book_metadata' ||
          ref.table_name === 'native_annotation_acks' ||
          ref.table_name === 'book_covers'
        )
          continue;
        const table = sql.identifier(ref.table_name);
        const column = sql.identifier(ref.column_name);
        const keys = STATE_KEYS[ref.table_name] ?? UNION_KEYS[ref.table_name];
        if (keys) {
          const joins = sql.join(
            keys.map((key) => sql`source.${sql.identifier(key)} is not distinct from target.${sql.identifier(key)}`),
            sql` and `,
          );
          await tx.execute(
            sql`delete from ${table} source using ${table} target where source.${column}=${source.id} and target.${column}=${target.id} and ${keys.length ? joins : sql`true`}`,
          );
        }
        if (['book_authors', 'book_narrators', 'book_series_memberships'].includes(ref.table_name)) {
          await tx.execute(sql`update ${table} set display_order=display_order+
            (select coalesce(max(display_order),-1)+1 from ${table} where ${column}=${target.id}) where ${column}=${source.id}`);
        }
        await tx.execute(sql`update ${table} set ${column}=${target.id} where ${column}=${source.id}`);
      }
      const metadataColumns = Object.values(getTableColumns(schema.bookMetadata)).filter((column) => !METADATA_IGNORED.includes(column.name));
      await tx.execute(sql`update book_metadata target set ${sql.join(
        metadataColumns.map(
          (column) => sql`${sql.identifier(column.name)}=coalesce(target.${sql.identifier(column.name)},source.${sql.identifier(column.name)})`,
        ),
        sql`, `,
      )},
        locked_fields = array(select distinct unnest(target.locked_fields || source.locked_fields)), updated_at=now()
        from book_metadata source where target.book_id=${target.id} and source.book_id=${source.id}`);
      // A destination cursor may be newer than the source items, including committed deletions.
      await tx.execute(
        sql`update annotations set change_sequence=nextval(pg_get_serial_sequence('annotations','change_sequence')) where book_id=${target.id}`,
      );
      await tx.execute(sql`update native_annotation_drafts set payload=jsonb_set(payload,'{bookId}',to_jsonb(${target.id}::integer))
        where book_id=${target.id} and payload->>'bookId'=${String(source.id)}`);
      await tx.execute(sql`delete from native_annotation_acks where book_id in (${source.id},${target.id})`);
      await tx
        .update(schema.books)
        .set({
          primaryFileId,
          primaryAuthorSortName: sql`(select coalesce(a.sort_name,a.name) from book_authors ba join authors a on a.id=ba.author_id
            where ba.book_id=${target.id} order by ba.display_order,a.id limit 1)`,
          updatedAt: new Date(),
        })
        .where(eq(schema.books.id, target.id));
      const result: MergeBooksResult = {
        sourceBookId: source.id,
        targetBookId: target.id,
        filesPreserved: preview.filesPreserved,
        alreadyApplied: false,
      };
      await tx.insert(schema.auditLog).values({
        userId: user.id,
        actorUsername: user.username,
        action: RECEIPT_ACTION,
        resource: 'book',
        resourceId: source.id,
        description: 'Duplicate book merged with files and reading history preserved',
        meta: {
          previewToken: preview.previewToken,
          result,
          libraryId: source.libraryId,
          libraryFolderId: source.libraryFolderId,
          sourceFolderPath: source.folderPath,
          targetFolderPath: target.folderPath,
          sourceFileIds: sourceFiles.map((file) => file.id),
          preservationIntent,
          preservationComplete: false,
        },
      });
      await deleteBooksWithHashInvalidation(tx, eq(schema.books.id, source.id));
      return result;
    });
  }
}
