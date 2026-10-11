import { BadRequestException, ConflictException, HttpException, Injectable, InternalServerErrorException, Logger } from '@nestjs/common';
import { sanitizeLogValue } from '../../common/utils/log-sanitize.utils';
import { BookMergeScanRepository } from './book-merge-scan.repository';
export type { BookMergeScanAlias } from './book-merge-scan.repository';

@Injectable()
export class BookMergeScanService {
  private readonly logger = new Logger(BookMergeScanService.name);
  constructor(private readonly repo: BookMergeScanRepository) {}

  async resolveMergedScanFolders(libraryId: number, libraryFolderId: number, sourceFolderPaths: string[]) {
    if (!sourceFolderPaths.length) return [];
    if (
      !Number.isInteger(libraryId) ||
      libraryId < 1 ||
      !Number.isInteger(libraryFolderId) ||
      libraryFolderId < 1 ||
      sourceFolderPaths.length > 1000 ||
      sourceFolderPaths.some((path) => typeof path !== 'string' || !path.length || path.length > 4096)
    )
      throw new BadRequestException('Merge scan lookup requires a library folder and at most 1000 candidate paths');
    const startedAt = Date.now();
    this.logger.log(
      `[book.duplicate_merge_scan_aliases] [start] libraryId=${libraryId} libraryFolderId=${libraryFolderId} pathCount=${sourceFolderPaths.length} - merge folder lookup started`,
    );
    try {
      const result = await this.repo.resolveAliases(libraryId, libraryFolderId, [...new Set(sourceFolderPaths)]);
      if (result.over_limit || result.ancestry_limit)
        throw new ConflictException('Merged folder history exceeds the safe scan batch; review it before scanning');
      const consolidated = new Map<string, (typeof result.aliases)[number]>();
      for (const alias of result.aliases) {
        const previous = consolidated.get(alias.sourceFolderPath);
        if (previous && previous.targetBook.id !== alias.targetBook.id)
          throw new ConflictException('Merged source folder belongs to multiple retained books; review its files before scanning');
        consolidated.set(alias.sourceFolderPath, {
          ...alias,
          fileIds: [...new Set([...(previous?.fileIds ?? []), ...alias.fileIds])],
        });
      }
      this.logger.log(
        `[book.duplicate_merge_scan_aliases] [end] libraryId=${libraryId} libraryFolderId=${libraryFolderId} pathCount=${sourceFolderPaths.length} durationMs=${Date.now() - startedAt} aliasCount=${consolidated.size} - merge folder lookup completed`,
      );
      return [...consolidated.values()];
    } catch (error) {
      this.logger.warn(
        `[book.duplicate_merge_scan_aliases] [fail] libraryId=${libraryId} libraryFolderId=${libraryFolderId} pathCount=${sourceFolderPaths.length} durationMs=${Date.now() - startedAt} errorClass=${error instanceof Error ? error.name : 'Unknown'} error="${sanitizeLogValue(error instanceof Error ? error.message : 'Lookup failed')}" - merge folder lookup failed`,
      );
      if (error instanceof HttpException) throw error;
      throw new InternalServerErrorException('Could not resolve retained merge files for this library folder');
    }
  }
}
