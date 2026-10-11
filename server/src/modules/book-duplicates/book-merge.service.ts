import { BadRequestException, ConflictException, HttpException, Injectable, InternalServerErrorException, Logger } from '@nestjs/common';
import type { MergeBooksRequest } from '@bookorbit/types';
import type { RequestUser } from '../../common/types/request-user';
import { sanitizeLogValue } from '../../common/utils/log-sanitize.utils';
import { BookService } from '../book/book.service';
import { BookMergeRepository } from './book-merge.repository';
import { BookMergeCoverService } from './book-merge-cover.service';

@Injectable()
export class BookMergeService {
  private readonly logger = new Logger(BookMergeService.name);

  constructor(
    private readonly repo: BookMergeRepository,
    private readonly books: BookService,
    private readonly covers: BookMergeCoverService,
  ) {}

  async preview(dto: MergeBooksRequest, user: RequestUser) {
    this.validatePair(dto);
    await this.books.verifyBookAccess(dto.sourceBookId, user);
    await this.books.verifyBookAccess(dto.targetBookId, user);
    const startedAt = Date.now();
    this.logger.log(
      `[book.duplicate_merge_preview] [start] sourceBookId=${dto.sourceBookId} targetBookId=${dto.targetBookId} userId=${user.id} - duplicate merge preview started`,
    );
    try {
      const preservationIntent = await this.covers.capture(dto.sourceBookId, dto.targetBookId);
      const result = await this.repo.preview(dto, user, preservationIntent);
      this.logger.log(
        `[book.duplicate_merge_preview] [end] sourceBookId=${dto.sourceBookId} targetBookId=${dto.targetBookId} userId=${user.id} durationMs=${Date.now() - startedAt} filesPreserved=${result.filesPreserved} blockerCount=${result.blockers.length} - duplicate merge preview completed`,
      );
      return result;
    } catch (error) {
      this.logger.warn(
        `[book.duplicate_merge_preview] [fail] sourceBookId=${dto.sourceBookId} targetBookId=${dto.targetBookId} userId=${user.id} durationMs=${Date.now() - startedAt} errorClass=${error instanceof Error ? error.name : 'Unknown'} error="${sanitizeLogValue(error instanceof Error ? error.message : 'Preview failed')}" - duplicate merge preview failed`,
      );
      if (error instanceof HttpException) throw error;
      throw new InternalServerErrorException('Could not preview the selected books');
    }
  }

  async apply(dto: MergeBooksRequest, user: RequestUser) {
    this.validatePair(dto);
    if (!dto.previewToken) throw new BadRequestException('Review a merge preview first');
    await this.books.verifyBookAccess(dto.targetBookId, user);
    const receipt = await this.repo.receipt(dto, user.id);
    if (receipt) {
      if (!receipt.preservationComplete) {
        try {
          await this.covers.finish(receipt.preservationIntent);
          await this.repo.markPreservationComplete(dto, user.id);
        } catch {
          throw new InternalServerErrorException('Book files were merged; cover preservation is pending. Retry the same preview');
        }
      }
      return receipt.result;
    }
    await this.books.verifyBookAccess(dto.sourceBookId, user);
    const startedAt = Date.now();
    let bookMergeCommitted = false;
    this.logger.log(
      `[book.duplicate_merge] [start] sourceBookId=${dto.sourceBookId} targetBookId=${dto.targetBookId} userId=${user.id} - duplicate merge started`,
    );
    try {
      const preservationIntent = await this.covers.capture(dto.sourceBookId, dto.targetBookId);
      const result = await this.repo.apply(dto, user, preservationIntent);
      bookMergeCommitted = true;
      const committed = await this.repo.receipt(dto, user.id);
      if (!committed) throw new InternalServerErrorException('Merge receipt is unavailable; retry the same merge preview');
      if (!committed.preservationComplete) {
        await this.covers.finish(committed.preservationIntent);
        await this.repo.markPreservationComplete(dto, user.id);
      }
      this.logger.log(
        `[book.duplicate_merge] [end] sourceBookId=${dto.sourceBookId} targetBookId=${dto.targetBookId} userId=${user.id} durationMs=${Date.now() - startedAt} filesPreserved=${result.filesPreserved} alreadyApplied=${result.alreadyApplied} - duplicate merge completed`,
      );
      return result;
    } catch (error) {
      this.logger.warn(
        `[book.duplicate_merge] [fail] sourceBookId=${dto.sourceBookId} targetBookId=${dto.targetBookId} userId=${user.id} durationMs=${Date.now() - startedAt} errorClass=${error instanceof Error ? error.name : 'Unknown'} error="${sanitizeLogValue(error instanceof Error ? error.message : 'Merge failed')}" - duplicate merge failed`,
      );
      if (error instanceof HttpException) throw error;
      const code = (error as { cause?: { code?: string }; code?: string })?.cause?.code ?? (error as { code?: string })?.code;
      if (['23505', '40001', '40P01'].includes(code ?? ''))
        throw new ConflictException('Reading data changed during merge; review a new preview and retry');
      throw new InternalServerErrorException(
        bookMergeCommitted
          ? 'Book files were merged; cover preservation is pending. Retry the same preview'
          : 'Merge could not be committed; no partial changes were applied',
      );
    }
  }

  private validatePair(dto: MergeBooksRequest) {
    if (dto.sourceBookId === dto.targetBookId) throw new BadRequestException('Choose two different books');
  }
}
