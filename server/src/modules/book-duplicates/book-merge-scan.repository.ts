import { Inject, Injectable } from '@nestjs/common';
import { sql } from 'drizzle-orm';
import type { NodePgDatabase } from 'drizzle-orm/node-postgres';
import { DB } from '../../db';
import * as schema from '../../db/schema';

export type BookMergeScanAlias = {
  sourceFolderPath: string;
  targetBook: Pick<typeof schema.books.$inferSelect, 'id' | 'status' | 'folderPath' | 'primaryFileId'>;
  fileIds: number[];
};

@Injectable()
export class BookMergeScanRepository {
  constructor(@Inject(DB) private readonly db: NodePgDatabase<typeof schema>) {}

  async resolveAliases(libraryId: number, libraryFolderId: number, sourceFolderPaths: string[]) {
    const indexedPatterns = sourceFolderPaths.map(
      (path) => `%${JSON.stringify(path).replaceAll('\\', '\\\\').replaceAll('%', '\\%').replaceAll('_', '\\_')}%`,
    );
    const [result] = (
      await this.db.execute<{ aliases: BookMergeScanAlias[]; over_limit: boolean; ancestry_limit: boolean }>(sql`
        with recursive receipts as materialized (
          select id, meta->>'sourceFolderPath' source_folder_path,
            (meta->'result'->>'targetBookId')::integer target_book_id, meta->>'targetFolderPath' target_folder_path,
            coalesce(meta->'sourceFileIds','[]'::jsonb) file_ids,
            jsonb_array_length(coalesce(meta->'sourceFileIds','[]'::jsonb)) file_count
          from audit_log where action='book.duplicate_merge' and resource='book'
            and meta::text like any(${sql.param(indexedPatterns)}::text[])
            and meta->>'libraryId'=${String(libraryId)} and meta->>'libraryFolderId'=${String(libraryFolderId)}
            and meta->>'sourceFolderPath'=any(${sql.param(sourceFolderPaths)}::text[])
          order by id desc limit 1001
        ), limits as (
          select count(*)>1000 or coalesce(sum(file_count),0)>100000 over_limit from receipts
        ), ancestry as (
          select r.id, r.source_folder_path, r.target_book_id, r.target_folder_path, r.file_ids, r.file_count, 0 depth
          from receipts r cross join limits where not limits.over_limit
          union all
          select previous.id, previous.source_folder_path, next.target_book_id, next.target_folder_path,
            previous.file_ids, previous.file_count, previous.depth+1
          from ancestry previous join lateral (
            select (meta->'result'->>'targetBookId')::integer target_book_id, meta->>'targetFolderPath' target_folder_path
            from audit_log where action='book.duplicate_merge' and resource='book' and resource_id=previous.target_book_id
              and meta->>'libraryId'=${String(libraryId)} and meta->>'libraryFolderId'=${String(libraryFolderId)}
            order by id desc limit 1
          ) next on true where previous.depth<64
        ), resolved as (
          select a.source_folder_path, a.file_ids, b.id, b.status, b.folder_path, b.primary_file_id
          from ancestry a join books b on b.id=a.target_book_id and b.library_id=${libraryId}
            and b.library_folder_id=${libraryFolderId} and b.folder_path=a.target_folder_path
          join lateral (
            select count(*)::integer matched, min(book_id) owner_min, max(book_id) owner_max
            from book_files where id in (select value::integer from jsonb_array_elements_text(a.file_ids))
          ) owned on owned.matched=a.file_count and owned.owner_min=b.id and owned.owner_max=b.id
          where a.file_count>0
        )
        select (select over_limit from limits) over_limit,
          exists(select 1 from ancestry a where a.depth=64 and not exists(select 1 from books where id=a.target_book_id)) ancestry_limit,
          coalesce((select jsonb_agg(jsonb_build_object(
            'sourceFolderPath', source_folder_path,
            'targetBook', jsonb_build_object('id',id,'status',status,'folderPath',folder_path,'primaryFileId',primary_file_id),
            'fileIds',file_ids
          )) from resolved),'[]'::jsonb) aliases
      `)
    ).rows;
    return result;
  }
}
