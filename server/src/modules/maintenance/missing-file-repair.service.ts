import { BadRequestException, ConflictException, Inject, Injectable, Logger, NotFoundException } from '@nestjs/common';
import { createHash } from 'crypto';
import { constants, createReadStream } from 'fs';
import { open } from 'fs/promises';
import { dirname, extname, relative } from 'path';
import { and, eq } from 'drizzle-orm';
import type { NodePgDatabase } from 'drizzle-orm/node-postgres';
import type { MissingFileRepairPreview, MissingFileRepairRequest, MissingFileRepairResult } from '@bookorbit/types';
import { DB } from '../../db';
import * as schema from '../../db/schema';
import type { RequestUser } from '../../common/types/request-user';
import { computeFileHashFromHandle } from '../../common/utils/file-hash.utils';
import { sanitizeLogValue } from '../../common/utils/log-sanitize.utils';
import { LibraryService } from '../library/library.service';
import { PathPolicyService } from '../path/path-policy.service';

@Injectable()
export class MissingFileRepairService {
  private readonly logger = new Logger(MissingFileRepairService.name);

  constructor(
    @Inject(DB) private readonly db: NodePgDatabase<typeof schema>,
    private readonly libraries: LibraryService,
    private readonly paths: PathPolicyService,
  ) {}

  private async context(input: MissingFileRepairRequest, user: RequestUser) {
    const [row] = await this.db
      .select({ book: schema.books, file: schema.bookFiles, root: schema.libraryFolders.path })
      .from(schema.books)
      .innerJoin(schema.bookFiles, and(eq(schema.bookFiles.bookId, schema.books.id), eq(schema.bookFiles.id, input.fileId)))
      .innerJoin(schema.libraryFolders, eq(schema.libraryFolders.id, schema.books.libraryFolderId))
      .where(eq(schema.books.id, input.bookId))
      .limit(1);
    if (!row) throw new NotFoundException('Book file not found');
    await this.libraries.verifyUserAccessLevel(user.id, row.book.libraryId, user.isSuperuser, 'editor');
    return row;
  }

  async preview(input: MissingFileRepairRequest, user: RequestUser): Promise<MissingFileRepairPreview> {
    const row = await this.context(input, user);
    const path = await this.paths.assertWithinRoot(input.replacementPath, row.root);
    let handle;
    try {
      handle = await open(path, constants.O_RDONLY | constants.O_NOFOLLOW);
    } catch {
      throw new BadRequestException('Replacement must be an existing regular file');
    }
    try {
      const before = await handle.stat({ bigint: true });
      if (!before.isFile()) throw new BadRequestException('Replacement must be a regular file');
      if (extname(path).toLowerCase() !== extname(row.file.absolutePath).toLowerCase()) {
        throw new ConflictException('Replacement format differs from the missing file');
      }
      if (row.file.sizeBytes == null || !row.file.fileHash) throw new ConflictException('The missing file has no verified identity');
      if (before.size !== BigInt(row.file.sizeBytes) || (await computeFileHashFromHandle(handle)) !== row.file.fileHash) {
        throw new ConflictException('Replacement content differs from the missing file');
      }
      const digest = createHash('sha256');
      for await (const chunk of createReadStream(path, { fd: handle.fd, autoClose: false, start: 0 })) digest.update(chunk);
      const after = await handle.stat({ bigint: true });
      if (before.size !== after.size || before.mtimeNs !== after.mtimeNs || before.ino !== after.ino) {
        throw new ConflictException('Replacement changed during verification');
      }
      const occupied = await this.db
        .select({ id: schema.bookFiles.id })
        .from(schema.bookFiles)
        .where(eq(schema.bookFiles.absolutePath, path))
        .limit(1);
      if (occupied.length && occupied[0].id !== input.fileId) throw new ConflictException('Replacement belongs to another book file');
      const alreadyApplied = row.file.absolutePath === path && row.book.status === 'present';
      if (!alreadyApplied && row.book.status !== 'missing') throw new ConflictException('Only a missing book file can be repaired');
      if (!alreadyApplied) {
        try {
          const original = await open(row.file.absolutePath, constants.O_RDONLY);
          await original.close();
          throw new ConflictException('The original file still exists');
        } catch (error) {
          if (!(error && typeof error === 'object' && 'code' in error && error.code === 'ENOENT')) throw error;
        }
      }
      const token = createHash('sha256')
        .update(
          JSON.stringify({
            userId: user.id,
            bookId: input.bookId,
            fileId: input.fileId,
            path,
            content: digest.digest('hex'),
            ino: String(after.ino),
            modified: String(after.mtimeNs),
          }),
        )
        .digest('hex');
      return {
        bookId: input.bookId,
        fileId: input.fileId,
        currentPath: row.file.absolutePath,
        replacementPath: path,
        previewToken: token,
        sizeBytes: Number(after.size),
        alreadyApplied,
      };
    } finally {
      await handle.close();
    }
  }

  async repair(input: MissingFileRepairRequest, user: RequestUser): Promise<MissingFileRepairResult> {
    const startedAt = Date.now();
    const event = 'maintenance.repair_file';
    this.logger.log(`[${event}] [start] bookId=${input.bookId} fileId=${input.fileId} userId=${user.id} - missing file repair started`);
    try {
      const preview = await this.preview(input, user);
      if (!input.previewToken || input.previewToken !== preview.previewToken)
        throw new ConflictException('Preview changed. Review the replacement again');
      if (!preview.alreadyApplied) {
        await this.db.transaction(async (tx) => {
          const [row] = await tx.select().from(schema.books).where(eq(schema.books.id, input.bookId)).for('update');
          if (!row) throw new NotFoundException('Book not found');
          const checked = await this.preview(input, user);
          if (checked.previewToken !== input.previewToken) throw new ConflictException('Replacement changed. Preview again');
          const files = await tx
            .select({ id: schema.bookFiles.id, path: schema.bookFiles.absolutePath })
            .from(schema.bookFiles)
            .where(eq(schema.bookFiles.bookId, row.id))
            .limit(2);
          const context = await this.context(input, user);
          const relPath = relative(context.root, checked.replacementPath);
          if (files.length > 1 && dirname(relPath) !== row.folderPath)
            throw new ConflictException('Repair a multi-file book inside its existing folder');
          if (files.length === 1) {
            const occupiedFolder = await tx
              .select({ id: schema.books.id })
              .from(schema.books)
              .where(and(eq(schema.books.libraryId, row.libraryId), eq(schema.books.folderPath, dirname(relPath))))
              .limit(1);
            if (occupiedFolder.length && occupiedFolder[0].id !== row.id) throw new ConflictException('Replacement folder belongs to another book');
          }
          const handle = await open(checked.replacementPath, constants.O_RDONLY | constants.O_NOFOLLOW);
          let stat;
          try {
            stat = await handle.stat({ bigint: true });
          } finally {
            await handle.close();
          }
          const updated = await tx
            .update(schema.bookFiles)
            .set({ absolutePath: checked.replacementPath, relPath, ino: stat.ino, mtime: new Date(Number(stat.mtimeMs)), updatedAt: new Date() })
            .where(
              and(
                eq(schema.bookFiles.id, input.fileId),
                eq(schema.bookFiles.bookId, input.bookId),
                eq(schema.bookFiles.absolutePath, checked.currentPath),
              ),
            )
            .returning({ id: schema.bookFiles.id });
          if (!updated.length) throw new ConflictException('Book file changed. Preview again');
          await tx
            .update(schema.books)
            .set({ status: 'present', ...(files.length === 1 ? { folderPath: dirname(relPath) } : {}), updatedAt: new Date() })
            .where(eq(schema.books.id, row.id));
        });
      }
      this.logger.log(
        `[${event}] [end] bookId=${input.bookId} fileId=${input.fileId} userId=${user.id} durationMs=${Date.now() - startedAt} alreadyApplied=${preview.alreadyApplied} - missing file repair completed`,
      );
      return { bookId: input.bookId, fileId: input.fileId, repaired: !preview.alreadyApplied, alreadyApplied: preview.alreadyApplied };
    } catch (error) {
      this.logger.error(
        `[${event}] [fail] bookId=${input.bookId} fileId=${input.fileId} userId=${user.id} durationMs=${Date.now() - startedAt} errorClass=${error instanceof Error ? error.name : 'Unknown'} error="${sanitizeLogValue(error instanceof Error ? error.message : String(error))}" - missing file repair failed`,
      );
      throw error;
    }
  }
}
