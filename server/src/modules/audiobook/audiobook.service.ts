import { createHash } from 'node:crypto';
import { basename } from 'node:path';

import { BadRequestException, ConflictException, Injectable, NotFoundException, PreconditionFailedException, Logger } from '@nestjs/common';
import {
  AUDIOBOOK_MANIFEST_SCHEMA,
  AUDIOBOOK_MANIFEST_VERSION,
  isAudioFormat,
  type AudiobookBookmark,
  type AudiobookBookmarksPage,
  type AudiobookBookmarksPageQuery,
  type AudiobookManifest,
  type AudiobookManifestAsset,
  type AudiobookManifestChapter,
  type AudiobookPlaybackState,
} from '@bookorbit/types';

import type { RequestUser } from '../../common/types/request-user';
import { compareAudioTracks } from '../../common/utils/book-media.utils';
import { BookService } from '../book/book.service';
import type { CreateAudiobookBookmarkDto } from './dto/create-audiobook-bookmark.dto';
import { sanitizeLogValue } from '../../common/utils/log-sanitize.utils';
import type { DeletePlaybackStateQueryDto } from './dto/delete-playback-state-query.dto';
import type { PutAudiobookPlaybackStateDto } from './dto/put-audiobook-playback-state.dto';
import type { UpdateAudiobookBookmarkDto } from './dto/update-audiobook-bookmark.dto';
import { AudiobookRepository } from './audiobook.repository';

type AudioFileRow = Awaited<ReturnType<AudiobookRepository['findAudioFiles']>>[number];

// Durations are stored as whole seconds, so a real position can sit up to half a second past the
// rounded duration. Accept a little beyond it and clamp, rather than refusing the tail of a track.
const DURATION_SLACK_MS = 1_000;

interface ManifestContext {
  manifest: AudiobookManifest;
  files: AudioFileRow[];
  libraryId: number;
  hasCompleteDurations: boolean;
}

@Injectable()
export class AudiobookService {
  private readonly logger = new Logger(AudiobookService.name);

  constructor(
    private readonly repo: AudiobookRepository,
    private readonly bookService: BookService,
  ) {}

  async getManifest(bookId: number, user: RequestUser): Promise<AudiobookManifest> {
    return (await this.loadManifestContext(bookId, user)).manifest;
  }

  async getAsset(bookId: number, assetId: string, user: RequestUser) {
    await this.bookService.verifyBookAccess(bookId, user);
    const row = await this.repo.findAsset(bookId, this.publicIdFromAssetId(assetId));
    if (!row || !row.format || !isAudioFormat(row.format)) throw new NotFoundException('Audiobook asset not found');
    const file = await this.bookService.getFileInfo(row.id, user);
    return {
      absolutePath: file.path,
      format: file.format,
      sizeBytes: file.size,
    };
  }

  async getPlaybackState(bookId: number, user: RequestUser): Promise<AudiobookPlaybackState | null> {
    const context = await this.loadManifestContext(bookId, user);
    const row = await this.repo.findPlaybackState(user.id, bookId);
    if (!row) return null;
    const file = context.files.find((candidate) => candidate.id === row.currentFileId);
    if (!file) return null;
    return {
      assetId: this.assetId(file.publicId),
      positionMs: Math.max(0, Math.round(row.positionSeconds * 1000)),
      percentage: row.percentage,
      completed: row.percentage >= 100,
      capturedAt: row.capturedAt.toISOString(),
      revision: row.revision,
      manifestRevision: row.manifestRevision ?? context.manifest.revision,
    };
  }

  async putPlaybackState(bookId: number, dto: PutAudiobookPlaybackStateDto, user: RequestUser): Promise<AudiobookPlaybackState> {
    const context = await this.loadManifestContext(bookId, user);
    if (dto.manifestRevision !== context.manifest.revision) {
      throw new PreconditionFailedException('Audiobook manifest has changed');
    }
    const fileIndex = context.files.findIndex((file) => this.assetId(file.publicId) === dto.assetId);
    if (fileIndex < 0) throw new BadRequestException('assetId does not belong to this audiobook');

    const previous = await this.repo.findPlaybackState(user.id, bookId);
    if (previous?.operationId?.toLowerCase() === dto.operationId.toLowerCase()) {
      const existing = (await this.getPlaybackState(bookId, user))!;
      await this.bookService.syncEbookProgressForAudiobookPlayback(
        user,
        bookId,
        previous.currentFileId,
        previous.positionSeconds,
        previous.percentage,
        previous.capturedAt,
      );
      return existing;
    }

    const asset = context.manifest.assets[fileIndex]!;
    if (asset.durationMs !== null && dto.positionMs > asset.durationMs + DURATION_SLACK_MS) {
      throw new BadRequestException('positionMs exceeds the asset duration');
    }
    const positionMs = asset.durationMs === null ? dto.positionMs : Math.min(dto.positionMs, asset.durationMs);
    const elapsedBefore = context.manifest.assets.slice(0, fileIndex).reduce((sum, item) => sum + (item.durationMs ?? 0), 0);
    const absolutePositionMs = elapsedBefore + positionMs;
    const percentage =
      context.hasCompleteDurations && context.manifest.totalDurationMs > 0
        ? Math.max(0, Math.min(100, (absolutePositionMs / context.manifest.totalDurationMs) * 100))
        : (previous?.percentage ?? 0);
    const values = {
      currentFileId: context.files[fileIndex]!.id,
      positionSeconds: positionMs / 1000,
      percentage,
      capturedAt: new Date(dto.capturedAt),
      operationId: dto.operationId,
      manifestRevision: dto.manifestRevision,
    };
    const saved =
      dto.baseRevision === 0
        ? await this.repo.createPlaybackState(user.id, bookId, values)
        : await this.repo.updatePlaybackState(user.id, bookId, dto.baseRevision, values);
    if (!saved) throw new ConflictException('Playback state revision conflict');

    const strongRereadEvidence = previous !== null && previous.percentage - percentage >= 10;
    await this.bookService.autoUpdateReadStatusForProgress(
      user.id,
      { bookId, libraryId: context.libraryId },
      percentage,
      strongRereadEvidence ? { origin: 'bookorbit', strongRereadEvidence: true } : {},
    );
    await this.bookService.syncEbookProgressForAudiobookPlayback(
      user,
      bookId,
      values.currentFileId,
      values.positionSeconds,
      percentage,
      saved.capturedAt,
    );
    return {
      assetId: dto.assetId,
      positionMs,
      percentage,
      completed: percentage >= 100,
      capturedAt: saved.capturedAt.toISOString(),
      revision: saved.revision,
      manifestRevision: dto.manifestRevision,
    };
  }

  async deletePlaybackState(bookId: number, user: RequestUser, condition: DeletePlaybackStateQueryDto = {}): Promise<void> {
    const startedAt = Date.now();
    this.logger.log(
      `[audiobook.clear_playback_state] [start] userId=${user.id} bookId=${bookId} conditional=${condition.baseRevision !== undefined} - position reset started`,
    );
    try {
      await this.bookService.verifyBookAccess(bookId, user);
      if (condition.manifestRevision !== undefined) {
        const context = await this.loadManifestContext(bookId, user);
        if (context.manifest.revision !== condition.manifestRevision)
          throw new PreconditionFailedException('The audiobook changed. Reopen it before resetting.');
      }
      const cleared =
        condition.baseRevision !== undefined
          ? await this.repo.deletePlaybackState(user.id, bookId, condition.baseRevision)
          : await this.repo.deletePlaybackState(user.id, bookId);
      if (cleared === false) throw new ConflictException('The listening position changed. Review its current position before resetting.');
      this.logger.log(
        `[audiobook.clear_playback_state] [end] userId=${user.id} bookId=${bookId} durationMs=${Date.now() - startedAt} cleared=true - position reset completed`,
      );
    } catch (error) {
      const errorClass = error instanceof Error ? error.constructor.name : 'Unknown';
      const message = sanitizeLogValue(error instanceof Error ? error.message : String(error));
      this.logger.error(
        `[audiobook.clear_playback_state] [fail] userId=${user.id} bookId=${bookId} durationMs=${Date.now() - startedAt} errorClass=${errorClass} error="${message}" - position reset failed`,
      );
      throw error;
    }
  }

  async listBookmarks(bookId: number, user: RequestUser): Promise<AudiobookBookmark[]> {
    await this.bookService.verifyBookAccess(bookId, user);
    const rows = await this.repo.findAudioBookmarks(user.id, bookId);
    return rows.map((row) => this.mapBookmark(row));
  }

  async listBookmarksPage(bookId: number, query: AudiobookBookmarksPageQuery, user: RequestUser): Promise<AudiobookBookmarksPage> {
    await this.bookService.verifyBookAccess(bookId, user);
    const limit = query.limit ?? 40;
    if (!Number.isInteger(limit) || limit < 1 || limit > 100) throw new BadRequestException('Bookmark page limit must be between 1 and 100');
    const after = query.afterId ? await this.repo.findAudioBookmark(user.id, bookId, query.afterId) : undefined;
    if (query.afterId && (!after || after.positionSeconds === null || !Number.isFinite(after.positionSeconds))) {
      throw new BadRequestException('Bookmark cursor is no longer available. Reload the first page.');
    }
    const rows = await this.repo.findAudioBookmarksPage(user.id, bookId, limit, after ?? undefined);
    const visible = rows.slice(0, limit);
    return {
      items: visible.map((row) => this.mapBookmark(row)),
      nextCursor: rows.length > limit ? (visible.at(-1)?.clientId ?? null) : null,
    };
  }

  async createBookmark(bookId: number, dto: CreateAudiobookBookmarkDto, user: RequestUser): Promise<AudiobookBookmark> {
    return this.bookmarkMutation('audiobook.bookmark_create', bookId, user.id, dto.clientId, async () => {
      const context = await this.loadManifestContext(bookId, user);
      const totalDurationMs = context.manifest.totalDurationMs;
      if (totalDurationMs > 0 && dto.positionMs > totalDurationMs + DURATION_SLACK_MS) {
        throw new BadRequestException('positionMs exceeds the audiobook duration');
      }
      if (dto.chapterId && !context.manifest.chapters.some((chapter) => chapter.id === dto.chapterId)) {
        throw new BadRequestException('chapterId does not belong to this audiobook manifest');
      }
      const row = await this.repo.createAudioBookmark(user.id, bookId, {
        clientId: dto.clientId,
        positionSeconds: (totalDurationMs > 0 ? Math.min(dto.positionMs, totalDurationMs) : dto.positionMs) / 1000,
        chapterId: dto.chapterId ?? null,
        title: dto.title,
        note: dto.note ?? null,
      });
      if (!row) throw new ConflictException('Audiobook bookmark already exists');
      if (row.deletedAt)
        throw new ConflictException('This audiobook bookmark creation was already deleted; use a new clientId for an explicit new bookmark');
      const positionSeconds = (totalDurationMs > 0 ? Math.min(dto.positionMs, totalDurationMs) : dto.positionMs) / 1000;
      if (row.positionSeconds !== positionSeconds) throw new ConflictException('Bookmark identity cannot be reused for a different location');
      return this.mapBookmark(row);
    });
  }

  async updateBookmark(bookId: number, bookmarkId: string, dto: UpdateAudiobookBookmarkDto, user: RequestUser): Promise<AudiobookBookmark> {
    await this.bookService.verifyBookAccess(bookId, user);
    if (dto.title === undefined && dto.note === undefined) {
      throw new BadRequestException('At least one bookmark field is required');
    }
    const row = await this.repo.updateAudioBookmark(user.id, bookId, bookmarkId, dto);
    if (!row) throw new NotFoundException('Audiobook bookmark not found');
    return this.mapBookmark(row);
  }

  async deleteBookmark(bookId: number, bookmarkId: string, user: RequestUser): Promise<void> {
    return this.bookmarkMutation('audiobook.bookmark_delete', bookId, user.id, bookmarkId, async () => {
      await this.bookService.verifyBookAccess(bookId, user);
      if (!(await this.repo.deleteAudioBookmark(user.id, bookId, bookmarkId))) {
        throw new NotFoundException('Audiobook bookmark not found');
      }
    });
  }

  private async bookmarkMutation<T>(event: string, bookId: number, userId: number, clientId: string, operation: () => Promise<T>): Promise<T> {
    const started = Date.now();
    this.logger.log(`[${event}] [start] bookId=${bookId} userId=${userId} clientId=${clientId} - audiobook bookmark mutation started`);
    try {
      const result = await operation();
      this.logger.log(
        `[${event}] [end] bookId=${bookId} userId=${userId} clientId=${clientId} durationMs=${Date.now() - started} saved=true - audiobook bookmark mutation completed`,
      );
      return result;
    } catch (error) {
      this.logger.warn(
        `[${event}] [fail] bookId=${bookId} userId=${userId} clientId=${clientId} durationMs=${Date.now() - started} errorClass=${error instanceof Error ? error.name : 'UnknownError'} error="${sanitizeLogValue(error instanceof Error ? error.message : 'Unknown error')}" - audiobook bookmark mutation failed`,
      );
      throw error;
    }
  }

  private async loadManifestContext(bookId: number, user: RequestUser): Promise<ManifestContext> {
    await this.bookService.verifyBookAccess(bookId, user);
    const [detail, rows] = await Promise.all([this.bookService.getDetail(bookId, user), this.repo.findAudioFiles(bookId)]);
    const files = rows.filter((row) => row.format !== null && isAudioFormat(row.format)).sort(compareAudioTracks);
    if (files.length === 0) throw new NotFoundException('Book has no audiobook assets');

    const revision = createHash('sha256')
      .update(
        JSON.stringify({
          files: files.map((file) => [file.publicId, file.sizeBytes, file.durationSeconds, file.mtime?.toISOString(), file.updatedAt.toISOString()]),
          chapters: detail.audioMetadata?.chapters ?? [],
        }),
      )
      .digest('hex');
    const assets = files.map<AudiobookManifestAsset>((file, sequence) => ({
      assetId: this.assetId(file.publicId),
      fileId: file.id,
      sequence,
      format: file.format!,
      durationMs: file.durationSeconds === null ? null : Math.round(file.durationSeconds * 1000),
      sizeBytes: file.sizeBytes,
      etag: createHash('sha256')
        .update(`${file.publicId}:${file.sizeBytes ?? ''}:${file.mtime?.getTime() ?? ''}`)
        .digest('hex'),
    }));
    const hasCompleteDurations = assets.every((asset) => asset.durationMs !== null && asset.durationMs > 0);
    const measuredDurationMs = assets.reduce((sum, asset) => sum + (asset.durationMs ?? 0), 0);
    const totalDurationMs = hasCompleteDurations
      ? measuredDurationMs
      : detail.audioMetadata?.durationSeconds !== null && detail.audioMetadata?.durationSeconds !== undefined
        ? Math.round(detail.audioMetadata.durationSeconds * 1000)
        : measuredDurationMs;
    const chapters = this.buildChapters(bookId, revision, detail.audioMetadata?.chapters ?? [], assets, totalDurationMs);
    return {
      libraryId: detail.libraryId,
      files,
      hasCompleteDurations,
      manifest: {
        schema: AUDIOBOOK_MANIFEST_SCHEMA,
        schemaVersion: AUDIOBOOK_MANIFEST_VERSION,
        revision,
        book: {
          id: bookId,
          title: detail.title ?? basename(detail.folderPath),
          authors: detail.authors.map((author) => author.name),
          narrators: detail.audioMetadata?.narrators.map((narrator) => narrator.name) ?? [],
          hasCover: detail.coverSource !== null,
        },
        assets,
        chapters,
        totalDurationMs,
      },
    };
  }

  private buildChapters(
    bookId: number,
    revision: string,
    chapters: { title: string; startMs: number }[],
    assets: AudiobookManifestAsset[],
    totalDurationMs: number,
  ): AudiobookManifestChapter[] {
    return [...chapters]
      .sort((left, right) => left.startMs - right.startMs)
      .map((chapter, sequence, ordered) => {
        const startMs = Math.max(0, Math.round(chapter.startMs));
        const endMs = Math.max(startMs, Math.round(ordered[sequence + 1]?.startMs ?? totalDurationMs));
        let elapsed = 0;
        let assetIndex = 0;
        for (let index = 0; index < assets.length; index += 1) {
          const duration = assets[index]!.durationMs ?? 0;
          if (index === assets.length - 1 || startMs < elapsed + duration) {
            assetIndex = index;
            break;
          }
          elapsed += duration;
        }
        return {
          id: `ch_${createHash('sha256').update(`${bookId}:${revision}:${sequence}:${startMs}`).digest('hex').slice(0, 32)}`,
          title: chapter.title,
          assetId: assets[assetIndex]!.assetId,
          sequence,
          startMs,
          endMs,
          assetOffsetMs: Math.max(0, startMs - elapsed),
        };
      });
  }

  private mapBookmark(row: Awaited<ReturnType<AudiobookRepository['findAudioBookmarksPage']>>[number]): AudiobookBookmark {
    return {
      id: row.clientId,
      bookId: row.bookId,
      positionMs: Math.max(0, Math.round((row.positionSeconds ?? 0) * 1000)),
      chapterId: row.chapterId,
      title: row.title,
      note: row.note,
      createdAt: row.createdAt.toISOString(),
      updatedAt: row.updatedAt.toISOString(),
    };
  }

  private assetId(publicId: string): string {
    return `aud_${publicId}`;
  }

  private publicIdFromAssetId(assetId: string): string {
    const publicId = assetId.startsWith('aud_') ? assetId.slice(4) : '';
    if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(publicId)) {
      throw new NotFoundException('Audiobook asset not found');
    }
    return publicId;
  }
}
