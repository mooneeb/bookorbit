import { randomUUID } from 'node:crypto';

import { BadRequestException, ForbiddenException, Injectable, Logger, NotFoundException } from '@nestjs/common';
import type {
  ReadingInsightsAccessHistoryPage,
  ReadingInsightsPreview,
  ReadingInsightsSharingLevel,
  ReadingInsightsSharingSettings,
  SharedReadingInsightsDetail,
  SharedReadingInsightsSummary,
  SharedReadingInsightsViewSession,
} from '@bookorbit/types';
import { AuditAction, AuditResource } from '@bookorbit/types';

import { sanitizeLogValue } from '../../common/utils/log-sanitize.utils';
import type { RequestUser } from '../../common/types/request-user';
import { AuditService } from '../audit/audit.service';
import { SharedReadingInsightsRepository } from './shared-reading-insights.repository';

const VIEW_SESSION_TTL_MS = 15 * 60 * 1000;

@Injectable()
export class SharedReadingInsightsService {
  private readonly logger = new Logger(SharedReadingInsightsService.name);
  constructor(
    private readonly repository: SharedReadingInsightsRepository,
    private readonly auditService: AuditService,
  ) {}

  async getMySettings(userId: number): Promise<ReadingInsightsSharingSettings> {
    const row = await this.repository.getSharingSettings(userId);
    if (!row) throw new NotFoundException('User not found');
    return this.mapSettings(row);
  }

  async updateMySettings(user: RequestUser, sharingLevel: ReadingInsightsSharingLevel): Promise<ReadingInsightsSharingSettings> {
    const started = Date.now();
    this.logger.log(`[reading_insights.update_sharing] [start] userId=${user.id} sharingLevel=${sharingLevel} - sharing preference started`);
    try {
      const consentedAt = sharingLevel === 'private' ? null : new Date();
      const row = await this.repository.updateSharingSettings(user.id, sharingLevel, consentedAt);
      if (!row) throw new NotFoundException('User not found');
      await this.auditService.record({
        userId: user.id,
        actorUsername: user.username,
        action: AuditAction.ReadingInsightsSharingUpdate,
        resource: AuditResource.ReadingInsightsProfile,
        resourceId: user.id,
        description: `User updated reading insights sharing to '${sharingLevel}'`,
        meta: { sharingLevel },
      });
      this.logger.log(
        `[reading_insights.update_sharing] [end] userId=${user.id} sharingLevel=${sharingLevel} durationMs=${Date.now() - started} consentGranted=${sharingLevel !== 'private'} sessionsRevoked=${sharingLevel === 'private'} - sharing preference completed`,
      );
      return this.mapSettings(row);
    } catch (error) {
      const errorClass = error instanceof Error ? error.constructor.name : 'UnknownError';
      const message = sanitizeLogValue(error instanceof Error ? error.message : String(error));
      this.logger.error(
        `[reading_insights.update_sharing] [fail] userId=${user.id} sharingLevel=${sharingLevel} durationMs=${Date.now() - started} errorClass=${errorClass} error="${message}" - sharing preference failed`,
      );
      throw error;
    }
  }

  async createViewSession(viewer: RequestUser, subjectUserId: number): Promise<SharedReadingInsightsViewSession> {
    const started = Date.now();
    this.logger.log(
      `[reading_insights.create_view] [start] viewerUserId=${viewer.id} subjectUserId=${subjectUserId} - shared insight access started`,
    );
    try {
      const subject = await this.repository.getSharingSettings(subjectUserId);
      if (!subject) throw new NotFoundException('User not found');
      if (subject.readingInsightsSharingLevel === 'private') {
        throw new ForbiddenException({ message: 'This user is not sharing reading insights', errorCode: 'READING_INSIGHTS_PRIVATE' });
      }
      const id = randomUUID();
      const expiresAt = new Date(Date.now() + VIEW_SESSION_TTL_MS);
      const created = await this.repository.createViewSession({
        id,
        viewerUserId: viewer.id,
        subjectUserId,
        sharingLevel: subject.readingInsightsSharingLevel,
        expiresAt,
      });
      if (created === false) {
        throw new ForbiddenException({ message: 'Sharing consent changed. Open the profile again.', errorCode: 'READING_INSIGHTS_CONSENT_CHANGED' });
      }
      await this.auditService.record({
        userId: viewer.id,
        actorUsername: viewer.username,
        action: AuditAction.ReadingInsightsProfileView,
        resource: AuditResource.ReadingInsightsProfile,
        resourceId: subjectUserId,
        description: `Viewed shared reading insights for user #${subjectUserId}`,
        meta: { subjectUserId, sharingLevel: subject.readingInsightsSharingLevel, viewSessionId: id },
      });
      this.logger.log(
        `[reading_insights.create_view] [end] viewerUserId=${viewer.id} subjectUserId=${subjectUserId} durationMs=${Date.now() - started} created=true sharingLevel=${subject.readingInsightsSharingLevel} - shared insight access completed`,
      );
      return { viewSessionId: id, sharingLevel: subject.readingInsightsSharingLevel, expiresAt: expiresAt.toISOString() };
    } catch (error) {
      const errorClass = error instanceof Error ? error.constructor.name : 'UnknownError';
      const message = sanitizeLogValue(error instanceof Error ? error.message : String(error));
      this.logger.error(
        `[reading_insights.create_view] [fail] viewerUserId=${viewer.id} subjectUserId=${subjectUserId} durationMs=${Date.now() - started} errorClass=${errorClass} error="${message}" - shared insight access failed`,
      );
      throw error;
    }
  }

  async getSharedSummary(
    viewer: RequestUser,
    subjectUserId: number,
    viewSessionId: string | undefined,
    days: number,
  ): Promise<SharedReadingInsightsSummary> {
    const sharingLevel = await this.authorizeView(viewer.id, subjectUserId, viewSessionId, 'summary');
    return this.buildSummary(subjectUserId, days, sharingLevel, viewer);
  }

  async getSharedDetail(
    viewer: RequestUser,
    subjectUserId: number,
    viewSessionId: string | undefined,
    days: number,
  ): Promise<SharedReadingInsightsDetail> {
    await this.authorizeView(viewer.id, subjectUserId, viewSessionId, 'detailed');
    return this.buildDetail(subjectUserId, days, viewer);
  }

  async getMyPreview(userId: number, days: number): Promise<ReadingInsightsPreview> {
    const settings = await this.getMySettings(userId);
    if (settings.sharingLevel === 'private') return settings;
    const summary = await this.buildSummary(userId, days, settings.sharingLevel);
    if (settings.sharingLevel === 'summary') return summary;
    return { summary, detail: await this.buildDetail(userId, days) };
  }

  async getMyAccessHistory(userId: number, page: number, pageSize: number): Promise<ReadingInsightsAccessHistoryPage> {
    const result = await this.auditService.getReadingInsightsAccess(userId, page, pageSize);
    return {
      items: result.items.map((item) => {
        const meta = item.meta as { sharingLevel?: unknown } | null;
        const sharingLevel = meta?.sharingLevel === 'detailed' ? 'detailed' : 'summary';
        return { id: item.id, viewerUsername: item.viewerUsername, sharingLevel, viewedAt: item.viewedAt.toISOString() };
      }),
      total: result.total,
      page,
      pageSize,
    };
  }

  private async authorizeView(
    viewerUserId: number,
    subjectUserId: number,
    viewSessionId: string | undefined,
    requiredLevel: 'summary' | 'detailed',
  ): Promise<'summary' | 'detailed'> {
    if (!viewSessionId) {
      throw new BadRequestException({ message: 'Reading insights view session is required', errorCode: 'READING_INSIGHTS_VIEW_SESSION_REQUIRED' });
    }
    const [session, subject] = await Promise.all([
      this.repository.getViewSession(viewSessionId, viewerUserId, subjectUserId),
      this.repository.getSharingSettings(subjectUserId),
    ]);
    if (!session) {
      throw new ForbiddenException({
        message: 'Reading insights view session is invalid or expired',
        errorCode: 'READING_INSIGHTS_VIEW_SESSION_INVALID',
      });
    }
    if (!subject || subject.readingInsightsSharingLevel === 'private') {
      throw new ForbiddenException({ message: 'This user is not sharing reading insights', errorCode: 'READING_INSIGHTS_PRIVATE' });
    }
    const effectiveLevel = session.sharingLevel === 'detailed' && subject.readingInsightsSharingLevel === 'detailed' ? 'detailed' : 'summary';
    if (requiredLevel === 'detailed' && effectiveLevel !== 'detailed') {
      throw new ForbiddenException({ message: 'This user shares summary insights only', errorCode: 'READING_INSIGHTS_SUMMARY_ONLY' });
    }
    return effectiveLevel;
  }

  private async buildSummary(
    userId: number,
    days: number,
    sharingLevel: 'summary' | 'detailed',
    viewer?: RequestUser,
  ): Promise<SharedReadingInsightsSummary> {
    const data = await this.repository.getSummary(userId, days, viewer);
    return {
      sharingLevel,
      periodDays: days,
      activeDays: data.daily.length,
      readingSeconds: data.daily.reduce((total, item) => total + item.readingSeconds, 0),
      sessionsCount: data.daily.reduce((total, item) => total + item.sessionsCount, 0),
      booksStarted: data.status.booksStarted,
      booksCompleted: data.status.booksCompleted,
      formatDistribution: data.formats,
      genreDistribution: data.genres,
      sourceCoverage: data.sources,
      trend: data.daily,
    };
  }

  private async buildDetail(userId: number, days: number, viewer?: RequestUser): Promise<SharedReadingInsightsDetail> {
    const data = await this.repository.getDetail(userId, days, viewer);
    const mapBooks = (items: typeof data.topBooks) =>
      items.map((item) => ({
        ...item,
        lastReadAt: item.lastReadAt instanceof Date ? item.lastReadAt.toISOString() : new Date(String(item.lastReadAt)).toISOString(),
      }));
    return {
      sharingLevel: 'detailed',
      periodDays: days,
      topBooks: mapBooks(data.topBooks),
      recentBooks: mapBooks(data.recentBooks),
      topAuthors: data.topAuthors,
      topGenres: data.topGenres,
      topSeries: data.topSeries,
      topNarrators: data.topNarrators,
    };
  }

  private mapSettings(row: {
    readingInsightsSharingLevel?: ReadingInsightsSharingLevel;
    readingInsightsConsentedAt?: Date | null;
    sharingLevel?: ReadingInsightsSharingLevel;
    consentedAt?: Date | null;
  }): ReadingInsightsSharingSettings {
    const sharingLevel = row.readingInsightsSharingLevel ?? row.sharingLevel ?? 'private';
    const consentedAt = row.readingInsightsConsentedAt ?? row.consentedAt ?? null;
    return { sharingLevel, consentedAt: consentedAt?.toISOString() ?? null };
  }
}
