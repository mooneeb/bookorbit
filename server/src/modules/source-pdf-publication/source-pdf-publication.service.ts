import {
  BadRequestException,
  ConflictException,
  ForbiddenException,
  Inject,
  Injectable,
  Logger,
  NotFoundException,
  Optional,
  ServiceUnavailableException,
} from '@nestjs/common';
import { randomUUID } from 'crypto';
import { open, rename, stat, unlink } from 'fs/promises';
import { dirname, join } from 'path';
import { PDFDocument } from 'pdf-lib';

import { Permission, type NativePdfPageSource } from '@bookorbit/types';
import type { RequestUser } from '../../common/types/request-user';
import { SelfWriteRegistry } from '../../common/services/self-write-registry.service';
import { computeFileHash } from '../../common/utils/file-hash.utils';
import { sanitizeLogValue } from '../../common/utils/log-sanitize.utils';
import { BookService } from '../book/book.service';
import { FileLockService } from '../file-write/file-lock.service';
import { FileWriteRepository } from '../file-write/file-write.repository';
import { replaceFileAtomically } from '../../common/utils/atomic-file-replace';
import {
  applySourcePdfInk,
  assertWritableSourcePdf,
  sourcePdfPageFingerprint,
  sourcePdfPageSize,
  sourcePdfRevision,
  sourcePdfInkVersion,
  type SourcePdfInkChange,
} from './source-pdf-ink';
import { SourcePdfPublicationRepository } from './source-pdf-publication.repository';
import {
  SourcePdfInspectionCache,
  sourcePdfFileIdentity,
  type SourcePdfInspectionFacts,
  type SourcePdfPageFacts,
} from './source-pdf-inspection-cache';

export interface SourcePdfPublicationInput extends Omit<SourcePdfInkChange, 'creatorUserId'> {
  bookId: number;
  bookFileId: number;
  user: RequestUser;
}

export interface SourcePdfPublicationResult {
  sourceRevision: string;
  published: boolean;
}

interface PendingPublication {
  input: SourcePdfPublicationInput;
  resolve: (result: SourcePdfPublicationResult) => void;
  reject: (error: unknown) => void;
}
interface PublicationJournal {
  bookId: number;
  fileId: number;
  before: string;
  after: string;
  tempPath: string;
  revisions: string[];
}
interface PublicationLineage {
  current: string;
  previous: string[];
}

const MAX_PENDING_FILES = 8;
const MAX_PENDING_OPERATIONS = 512;
const EVENT = 'pdf_ink.publish';

export const SOURCE_PDF_PUBLICATION_BOUNDARY = 'SOURCE_PDF_PUBLICATION_BOUNDARY';
export interface SourcePdfPublicationBoundary {
  onPhase(input: { phase: 'prepared' | 'committed'; bookId: number; bookFileId: number; operationIds: string[] }): Promise<void>;
}

@Injectable()
export class SourcePdfPublicationService {
  private readonly logger = new Logger(SourcePdfPublicationService.name);
  private readonly pending = new Map<number, { operations: PendingPublication[]; timer: ReturnType<typeof setTimeout> }>();
  private activePublications = 0;
  private readonly inspectionCache = new SourcePdfInspectionCache();

  constructor(
    private readonly bookService: BookService,
    private readonly lockService: FileLockService,
    private readonly fileWriteRepository: FileWriteRepository,
    private readonly repository: SourcePdfPublicationRepository,
    private readonly selfWriteRegistry: SelfWriteRegistry,
    @Optional() @Inject(SOURCE_PDF_PUBLICATION_BOUNDARY) private readonly boundary?: SourcePdfPublicationBoundary,
  ) {}

  async inspectPage(bookId: number, bookFileId: number, page: number, user: RequestUser, requestedRevision?: string): Promise<NativePdfPageSource> {
    return (await this.inspectPages(bookId, bookFileId, page, 1, user, requestedRevision)).pages[0];
  }

  async inspectPages(bookId: number, bookFileId: number, pageStart: number, limit: number, user: RequestUser, requestedRevision?: string) {
    if (!Number.isInteger(pageStart) || pageStart < 0 || !Number.isInteger(limit) || limit < 1 || limit > 100) {
      throw new BadRequestException('Invalid PDF page range');
    }
    const file = await this.target(bookId, bookFileId, user, false);
    return this.lockService.withLock(file.absolutePath, async () => {
      const state = await stat(file.absolutePath, { bigint: true }).catch(() => {
        throw new NotFoundException('Source PDF no longer exists');
      });
      if (!state.isFile() || state.size > BigInt(file.maxFileSizeBytes))
        throw new BadRequestException('Source PDF exceeds the safe publication size limit');
      const identity = sourcePdfFileIdentity(state);
      let facts = this.inspectionCache.get(file.absolutePath, identity);
      if (facts && pageStart >= facts.pageCount) throw new BadRequestException('Invalid PDF page range');
      const cachedEnd = facts ? Math.min(pageStart + limit, facts.pageCount) : 0;
      let missingPages = !facts;
      for (let page = pageStart; facts && page < cachedEnd; page++) {
        if (!facts.pages.has(page)) {
          missingPages = true;
          break;
        }
      }
      if (missingPages)
        facts = await this.inspectionCache.load(async () => {
          const bytes = await this.readBounded(file.absolutePath, file.maxFileSizeBytes);
          const document = await this.load(bytes);
          if (pageStart >= document.getPageCount()) throw new BadRequestException('Invalid PDF page range');
          let protectedDocument = false;
          try {
            assertWritableSourcePdf(document);
          } catch {
            protectedDocument = true;
          }
          const pages = new Map<number, SourcePdfPageFacts>();
          const end = Math.min(pageStart + limit, document.getPageCount());
          for (let page = pageStart; page < end; page++) {
            const targetPage = document.getPage(page);
            pages.set(page, { pageFingerprint: sourcePdfPageFingerprint(document, targetPage), ...sourcePdfPageSize(targetPage), page });
          }
          const after = await stat(file.absolutePath, { bigint: true }).catch(() => {
            throw new NotFoundException('Source PDF no longer exists');
          });
          if (sourcePdfFileIdentity(after) !== identity)
            throw new ConflictException('Source PDF changed during inspection; retry with the current file');
          const loaded: SourcePdfInspectionFacts = {
            sourceRevision: sourcePdfRevision(bytes),
            protectedDocument,
            pageCount: document.getPageCount(),
            pages,
          };
          this.inspectionCache.put(file.absolutePath, identity, loaded);
          return this.inspectionCache.get(file.absolutePath, identity)!;
        });
      const { sourceRevision, protectedDocument, pageCount } = facts!;
      const lineage = requestedRevision ? await this.readLineage(file.absolutePath, bookFileId) : null;
      const matchedSourceRevision =
        requestedRevision &&
        (requestedRevision === sourceRevision || (lineage?.current === sourceRevision && lineage.previous.includes(requestedRevision)))
          ? requestedRevision
          : null;
      const pages: NativePdfPageSource[] = [];
      const end = Math.min(pageStart + limit, pageCount);
      for (let page = pageStart; page < end; page++) {
        pages.push({
          sourceRevision,
          ...facts!.pages.get(page)!,
          matchedSourceRevision,
          canEditPdfInk: this.canWrite(user) && file.pdfEnabled && !protectedDocument && (!requestedRevision || matchedSourceRevision != null),
        });
      }
      return { sourceRevision, pages, nextPage: end < pageCount ? end : null };
    });
  }

  publish(input: SourcePdfPublicationInput): Promise<SourcePdfPublicationResult> {
    if (!this.canWrite(input.user)) return Promise.reject(new ForbiddenException('Editing source PDF ink requires library editing permission'));
    const existing = this.pending.get(input.bookFileId);
    if (
      (!existing && this.pending.size + this.activePublications >= MAX_PENDING_FILES) ||
      (existing && existing.operations.length >= MAX_PENDING_OPERATIONS)
    ) {
      return Promise.reject(new ServiceUnavailableException('PDF publication queue is full; retry the retained operation'));
    }
    return new Promise((resolve, reject) => {
      const operation = { input, resolve, reject };
      if (existing) existing.operations.push(operation);
      else
        this.pending.set(input.bookFileId, {
          operations: [operation],
          timer: setTimeout(() => {
            void this.flush(input.bookFileId);
          }, 250),
        });
    });
  }

  cancelPending(operationId: string, userId: number): boolean {
    for (const [fileId, batch] of this.pending) {
      const index = batch.operations.findIndex(({ input }) => input.operationId === operationId && input.user.id === userId);
      if (index < 0) continue;
      const [operation] = batch.operations.splice(index, 1);
      operation.reject(new ConflictException('PDF publication was canceled before commit'));
      if (!batch.operations.length) {
        clearTimeout(batch.timer);
        this.pending.delete(fileId);
      }
      return true;
    }
    return false;
  }

  private canWrite(user: RequestUser): boolean {
    return (
      user.active &&
      !user.permissions.includes(Permission.DemoRestricted) &&
      (user.isSuperuser || user.permissions.includes(Permission.LibraryEditMetadata))
    );
  }

  private async target(bookId: number, fileId: number, user: RequestUser, requireWrite: boolean) {
    if (requireWrite && !this.canWrite(user)) throw new ForbiddenException('Editing source PDF ink requires library editing permission');
    const file = await this.bookService.verifyFileAccess(fileId, user);
    if (file.bookId !== bookId || file.format?.toLowerCase() !== 'pdf')
      throw new BadRequestException('Source ink requires the selected PDF book file');
    const configuration = await this.fileWriteRepository.findLibraryFileWriteConfig(file.libraryId);
    if (requireWrite && !configuration?.fileWritePdfEnabled) throw new ForbiddenException('PDF source writing is disabled for this library');
    const maxFileSizeBytes = Math.min(configuration?.fileWritePdfMaxFileSizeMb ?? 100, 100) * 1024 * 1024;
    return { ...file, maxFileSizeBytes, pdfEnabled: configuration?.fileWritePdfEnabled ?? false };
  }

  private async flush(fileId: number): Promise<void> {
    const batch = this.pending.get(fileId);
    if (!batch) return;
    if (this.activePublications >= 2) return;
    this.activePublications++;
    this.pending.delete(fileId);
    clearTimeout(batch.timer);
    const startedAt = Date.now();
    const first = batch.operations[0].input;
    this.logger.log(
      `[${EVENT}] [start] bookId=${first.bookId} bookFileId=${fileId} userId=${first.user.id} operations=${batch.operations.length} - source ink publication started`,
    );
    try {
      const target = await this.target(first.bookId, fileId, first.user, true);
      const result = await this.lockService.withLock(target.absolutePath, () =>
        this.selfWriteRegistry.track([target.absolutePath], async () => {
          const verifiedUsers = new Set<string>();
          for (const { input } of batch.operations) {
            const accessKey = `${input.user.id}:${input.bookId}`;
            if (verifiedUsers.has(accessKey)) continue;
            const current = await this.target(input.bookId, fileId, input.user, true);
            if (current.absolutePath !== target.absolutePath) throw new ConflictException('Source PDF was moved or replaced');
            verifiedUsers.add(accessKey);
          }
          await this.recover(target.absolutePath, first.bookId, fileId);
          const original = await this.readBounded(target.absolutePath, target.maxFileSizeBytes);
          const before = sourcePdfRevision(original);
          const lineage = await this.readLineage(target.absolutePath, fileId);
          const document = await this.load(original);
          assertWritableSourcePdf(document);
          const creators = await this.repository.findInkCreators(first.bookId, fileId, [
            ...new Set(batch.operations.map(({ input }) => input.annotationId)),
          ]);
          let changes = 0;
          for (const { input } of batch.operations.sort((left, right) => left.input.version - right.input.version)) {
            if (sourcePdfInkVersion(document, input.annotationId) >= input.version) continue;
            if (!input.sourceRevision) throw new ConflictException('A source PDF revision is required; retain this ink as a recovery draft');
            const knownInkRevision = input.pageFingerprint && lineage?.current === before && lineage.previous.includes(input.sourceRevision);
            if (input.sourceRevision !== before && !knownInkRevision) {
              throw new ConflictException('The source PDF changed; retain this operation as a recovery draft');
            }
            const creatorUserId = creators.get(input.annotationId);
            if (creatorUserId == null) throw new ConflictException('Source ink no longer matches the canonical book file');
            if (applySourcePdfInk(document, { ...input, creatorUserId })) changes++;
          }
          if (!changes) {
            await this.refreshState(target.absolutePath, first.bookId, fileId);
            return { sourceRevision: before, published: false };
          }
          const saved = await document.save({ updateFieldAppearances: false });
          const after = sourcePdfRevision(saved);
          const tempPath = join(dirname(target.absolutePath), `.bookorbit-ink-${fileId}-${randomUUID()}.pdf`);
          const journalPath = this.journalPath(target.absolutePath, fileId);
          const revisions = [before, ...(lineage?.current === before ? lineage.previous : [])].slice(0, 1024);
          await this.writeDurable(tempPath, saved);
          await this.writeJournal(journalPath, { bookId: first.bookId, fileId, before, after, tempPath, revisions });
          await this.boundary?.onPhase({
            phase: 'prepared',
            bookId: first.bookId,
            bookFileId: fileId,
            operationIds: batch.operations.map(({ input }) => input.operationId),
          });
          const current = await this.target(first.bookId, fileId, first.user, true);
          if (
            current.absolutePath !== target.absolutePath ||
            sourcePdfRevision(await this.readBounded(target.absolutePath, target.maxFileSizeBytes)) !== before
          ) {
            await unlink(tempPath).catch(() => {});
            await unlink(journalPath).catch(() => {});
            throw new ConflictException('Source PDF changed during publication; no ink was written');
          }
          await replaceFileAtomically(tempPath, target.absolutePath);
          await this.syncDirectory(dirname(target.absolutePath));
          await this.boundary?.onPhase({
            phase: 'committed',
            bookId: first.bookId,
            bookFileId: fileId,
            operationIds: batch.operations.map(({ input }) => input.operationId),
          });
          await this.refreshState(target.absolutePath, first.bookId, fileId);
          await this.writeJson(this.lineagePath(target.absolutePath, fileId), { current: after, previous: revisions });
          await unlink(journalPath);
          return { sourceRevision: after, published: true };
        }),
      );
      for (const operation of batch.operations) operation.resolve(result);
      this.logger.log(
        `[${EVENT}] [end] bookId=${first.bookId} bookFileId=${fileId} userId=${first.user.id} durationMs=${Date.now() - startedAt} operations=${batch.operations.length} published=${result.published} - source ink publication completed`,
      );
    } catch (error) {
      this.logger.warn(
        `[${EVENT}] [fail] bookId=${first.bookId} bookFileId=${fileId} userId=${first.user.id} durationMs=${Date.now() - startedAt} errorClass=${error instanceof Error ? error.constructor.name : 'Unknown'} error="${sanitizeLogValue(error instanceof Error ? error.message : 'unknown failure')}" - source ink publication failed`,
      );
      for (const operation of batch.operations) operation.reject(error);
    } finally {
      this.activePublications--;
      for (const nextFileId of this.pending.keys()) {
        if (this.activePublications >= 2) break;
        void this.flush(nextFileId);
      }
    }
  }

  private async load(bytes: Uint8Array): Promise<PDFDocument> {
    try {
      return await PDFDocument.load(bytes, { ignoreEncryption: true, updateMetadata: false });
    } catch {
      throw new BadRequestException('Source PDF cannot be parsed safely');
    }
  }

  private async readBounded(path: string, limit: number): Promise<Buffer> {
    const handle = await open(path, 'r').catch(() => {
      throw new NotFoundException('Source PDF no longer exists');
    });
    try {
      const state = await handle.stat();
      if (!state.isFile() || state.size > limit) throw new BadRequestException('Source PDF exceeds the safe publication size limit');
      const bytes = Buffer.alloc(state.size);
      let offset = 0;
      while (offset < bytes.length) {
        const { bytesRead } = await handle.read(bytes, offset, bytes.length - offset, offset);
        if (!bytesRead) break;
        offset += bytesRead;
      }
      const after = await handle.stat();
      if (offset !== bytes.length || after.size !== state.size || after.mtimeMs !== state.mtimeMs || after.ctimeMs !== state.ctimeMs) {
        throw new ConflictException('Source PDF changed while reading; retry with the current revision');
      }
      return bytes;
    } finally {
      await handle.close();
    }
  }

  private async refreshState(path: string, bookId: number, fileId: number): Promise<void> {
    const state = await stat(path, { bigint: true });
    await this.repository.updatePublishedFile(bookId, fileId, {
      fileHash: await computeFileHash(path),
      mtime: state.mtime,
      sizeBytes: Number(state.size),
      ino: state.ino,
    });
  }

  private journalPath(path: string, fileId: number): string {
    return join(dirname(path), `.bookorbit-ink-${fileId}.json`);
  }

  private async recover(path: string, bookId: number, fileId: number): Promise<void> {
    const journalPath = this.journalPath(path, fileId);
    let journal: PublicationJournal;
    try {
      const bytes = await this.readSidecar(journalPath);
      if (!bytes) return;
      journal = JSON.parse(bytes.toString('utf8')) as PublicationJournal;
    } catch {
      throw new ConflictException('PDF publication recovery journal is unreadable; source content was preserved');
    }
    if (
      journal.bookId !== bookId ||
      journal.fileId !== fileId ||
      typeof journal.tempPath !== 'string' ||
      !/^sha256:[a-f0-9]{64}$/.test(journal.before) ||
      !/^sha256:[a-f0-9]{64}$/.test(journal.after) ||
      !Array.isArray(journal.revisions) ||
      journal.revisions.length > 1024 ||
      !journal.revisions.every((revision) => /^sha256:[a-f0-9]{64}$/.test(revision)) ||
      dirname(journal.tempPath) !== dirname(path) ||
      !journal.tempPath.startsWith(join(dirname(path), `.bookorbit-ink-${fileId}-`))
    ) {
      throw new ConflictException('PDF publication recovery journal does not match this source');
    }
    const current = sourcePdfRevision(await this.readBounded(path, 100 * 1024 * 1024));
    if (current === journal.before) {
      const temporary = await this.readBounded(journal.tempPath, 100 * 1024 * 1024);
      if (sourcePdfRevision(temporary) !== journal.after) throw new ConflictException('Incomplete PDF publication was preserved for recovery');
      await replaceFileAtomically(journal.tempPath, path);
      await this.syncDirectory(dirname(path));
    } else if (current !== journal.after) {
      throw new ConflictException('Source PDF was replaced after interrupted publication; retain the old ink as a recovery draft');
    }
    await this.refreshState(path, bookId, fileId);
    await this.writeJson(this.lineagePath(path, fileId), { current: journal.after, previous: journal.revisions });
    await unlink(journalPath);
  }

  private async writeDurable(path: string, bytes: Uint8Array): Promise<void> {
    const handle = await open(path, 'wx', 0o600);
    try {
      await handle.writeFile(bytes);
      await handle.sync();
    } finally {
      await handle.close();
    }
  }

  private async writeJournal(path: string, journal: PublicationJournal): Promise<void> {
    await this.writeJson(path, journal);
  }

  private lineagePath(path: string, fileId: number): string {
    return join(dirname(path), `.bookorbit-ink-${fileId}-revisions.json`);
  }

  private async readLineage(path: string, fileId: number): Promise<PublicationLineage | null> {
    try {
      const bytes = await this.readSidecar(this.lineagePath(path, fileId));
      if (!bytes) return null;
      const value = JSON.parse(bytes.toString('utf8')) as PublicationLineage;
      if (
        !/^sha256:[a-f0-9]{64}$/.test(value.current) ||
        !Array.isArray(value.previous) ||
        value.previous.length > 1024 ||
        !value.previous.every((revision) => /^sha256:[a-f0-9]{64}$/.test(revision))
      ) {
        throw new ConflictException('PDF source revision history is invalid; source content was preserved');
      }
      return value;
    } catch {
      throw new ConflictException('PDF source revision history is unreadable; source content was preserved');
    }
  }

  private async readSidecar(path: string): Promise<Buffer | null> {
    try {
      await stat(path);
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code === 'ENOENT') return null;
      throw new ConflictException('PDF publication recovery state cannot be read');
    }
    return this.readBounded(path, 128 * 1024);
  }

  private async writeJson(path: string, value: PublicationJournal | PublicationLineage): Promise<void> {
    const temporary = `${path}.${randomUUID()}.tmp`;
    try {
      await this.writeDurable(temporary, Buffer.from(JSON.stringify(value)));
      await rename(temporary, path);
      await this.syncDirectory(dirname(path));
    } finally {
      await unlink(temporary).catch(() => {});
    }
  }

  private async syncDirectory(path: string): Promise<void> {
    const handle = await open(path, 'r');
    try {
      await handle.sync();
    } finally {
      await handle.close();
    }
  }
}
