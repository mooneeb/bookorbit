import { BadRequestException, ConflictException, HttpException, Injectable, Logger, ServiceUnavailableException } from '@nestjs/common';
import { isAudioFormat, type BookContinuationResponse, type BookContinuationUnavailableReason } from '@bookorbit/types';
import { sanitizeLogValue } from '../../common/utils/log-sanitize.utils';
import type { RequestUser } from '../../common/types/request-user';
import { AudiobookEbookProgressSyncService } from './audiobook-ebook-progress-sync.service';
import { BookRepository } from './book.repository';
import { BookService } from './book.service';
import type { BookContinuationQueryDto } from './dto/book-continuation-query.dto';

@Injectable()
export class BookContinuationService {
  private readonly logger = new Logger(BookContinuationService.name);
  constructor(
    private readonly books: BookService,
    private readonly repo: BookRepository,
    private readonly sync: AudiobookEbookProgressSyncService,
  ) {}

  async resolve(bookId: number, query: BookContinuationQueryDto, user: RequestUser): Promise<BookContinuationResponse> {
    const startedAt = Date.now();
    this.logger.log(
      `[book.continuation] [start] userId=${user.id} bookId=${bookId} sourceFileId=${query.sourceFileId} direction=${query.direction} - continuation resolution started`,
    );
    try {
      const result = await this.resolveSaved(bookId, query, user);
      this.logger.log(
        `[book.continuation] [end] userId=${user.id} bookId=${bookId} sourceFileId=${query.sourceFileId} durationMs=${Date.now() - startedAt} state=${result.state} targets=${result.targets.length} - continuation resolution completed`,
      );
      return result;
    } catch (error: unknown) {
      const errorClass = error instanceof Error ? error.constructor.name : 'UnknownError';
      const message = sanitizeLogValue(error instanceof Error ? error.message : String(error));
      this.logger.warn(
        `[book.continuation] [fail] userId=${user.id} bookId=${bookId} sourceFileId=${query.sourceFileId} durationMs=${Date.now() - startedAt} errorClass=${errorClass} error="${message}" - continuation resolution failed`,
      );
      if (error instanceof HttpException) throw error;
      throw new ServiceUnavailableException('The narration mapping could not be read. Try again later.');
    }
  }

  private async resolveSaved(bookId: number, query: BookContinuationQueryDto, user: RequestUser): Promise<BookContinuationResponse> {
    await this.books.verifyBookAccess(bookId, user);
    const file = await this.books.verifyFileAccess(query.sourceFileId, user);
    if (file.bookId !== bookId) throw new BadRequestException('Source file does not belong to this book');
    if (file.role !== 'content' && file.role !== 'primary') return this.unavailable('unsupported_source', query.sourceFileId);
    if (query.direction === 'text_to_audio') {
      if (!query.textCfi || query.audioRevision !== undefined) throw new BadRequestException('Text continuation requires only textCfi');
      if (file.format?.toLowerCase() !== 'epub') return this.unavailable('unsupported_source', query.sourceFileId);
      const source = await this.repo.findProgress(user.id, file.id);
      if (!source || source.cfi !== query.textCfi) throw new ConflictException('Reading position changed. Save the passage again before continuing.');
      const resolution = await this.sync.resolveContinuation({
        userId: user.id,
        bookId,
        direction: query.direction,
        sourceFileId: file.id,
        cfi: source.cfi,
        percentage: source.percentage,
      });
      if (resolution.state !== 'ready') return resolution;
      const audio = await this.repo.findAudioProgress(user.id, bookId);
      resolution.targets = resolution.targets.filter(
        (target) =>
          audio?.currentFileId === target.fileId && target.positionMs !== null && Math.abs(audio.positionSeconds * 1000 - target.positionMs) <= 1,
      );
      const current = await this.repo.findProgress(user.id, file.id);
      if (current?.cfi !== source.cfi || current?.updatedAt.getTime() !== source.updatedAt.getTime()) {
        throw new ConflictException('Reading position changed while resolving continuation');
      }
      return this.confirm(resolution);
    }

    if (query.audioRevision === undefined || query.textCfi !== undefined)
      throw new BadRequestException('Audio continuation requires only audioRevision');
    if (!file.format || !isAudioFormat(file.format)) return this.unavailable('unsupported_source', query.sourceFileId);
    const source = await this.repo.findAudioProgress(user.id, bookId);
    if (!source || source.revision !== query.audioRevision || source.currentFileId !== file.id) {
      throw new ConflictException('Listening position changed. Save the listening position again before continuing.');
    }
    const resolution = await this.sync.resolveContinuation({
      userId: user.id,
      bookId,
      direction: query.direction,
      sourceFileId: file.id,
      positionSeconds: source.positionSeconds,
      percentage: source.percentage,
      audioRevision: source.revision,
    });
    if (resolution.state !== 'ready') return resolution;
    const saved = await this.repo.findContinuationProgress(
      user.id,
      resolution.targets.map((target) => target.fileId),
    );
    const byFile = new Map(saved.map((progress) => [progress.bookFileId, progress.cfi]));
    resolution.targets = resolution.targets.filter((target) => byFile.get(target.fileId) === target.cfi);
    const current = await this.repo.findAudioProgress(user.id, bookId);
    if (current?.revision !== source.revision) throw new ConflictException('Listening position changed while resolving continuation');
    return this.confirm(resolution);
  }

  private confirm(resolution: BookContinuationResponse): BookContinuationResponse {
    return resolution.targets.length ? resolution : { ...resolution, state: 'unavailable', reason: 'position_not_synced' };
  }

  private unavailable(reason: BookContinuationUnavailableReason, sourceFileId: number): BookContinuationResponse {
    return {
      sourceFileId,
      sourceTextCfi: null,
      sourceAudioRevision: null,
      sourcePositionMs: null,
      accuracy: null,
      state: 'unavailable',
      reason,
      overlayFileId: null,
      targets: [],
    };
  }
}
