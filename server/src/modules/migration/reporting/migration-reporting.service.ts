import { Readable } from 'node:stream';
import { BadRequestException, ForbiddenException, Injectable, Logger, NotFoundException } from '@nestjs/common';

import type { RequestUser } from '../../../common/types/request-user';
import { sanitizeLogValue } from '../../../common/utils/log-sanitize.utils';
import type { SourceBook } from '../adapters/source-adapter.types';
import { asRecord } from '../core/coerce';
import { sanitizeRunForApi } from '../core/api-sanitizers';
import { MigrationRepository } from '../migration.repository';
import type { PlannedBookMatch, PlannedDuplicateBookMatch, PlannedUserPreview } from '../planner/planner.types';
import { MigrationReportRepository, type DuplicateArrayField, type PlanArrayField } from './migration-report.repository';

type Artifact = NonNullable<Awaited<ReturnType<MigrationReportRepository['findArtifact']>>>;
type DetailKind = 'matched' | 'unresolved' | 'duplicate' | 'users';
const DETAIL_FIELDS = { matched: 'matchedBooks', unresolved: 'unresolvedBooks', duplicate: 'duplicateBookMatches', users: 'userPreview' } as const;
const PREVIEW_LIMIT = 40;
const EXPORT_LIMIT = 100;
const CSV_HEADERS = [
  'section',
  'stage',
  'entityType',
  'processed',
  'imported',
  'skipped',
  'unresolved',
  'failed',
  'sourceBookId',
  'sourceTitle',
  'sourceAuthor',
  'targetBookId',
  'targetTitle',
  'strategy',
  'sourceUserId',
  'targetUserId',
  'username',
  'reason',
  'details',
  'code',
  'message',
  'createdAt',
];
type CsvRow = Record<string, string | number | null | undefined>;

@Injectable()
export class MigrationReportingService {
  private readonly logger = new Logger(MigrationReportingService.name);

  constructor(
    private readonly repo: MigrationRepository,
    private readonly reports: MigrationReportRepository,
  ) {}

  async getRunReport(runId: number, user: RequestUser) {
    const context = await this.context(runId, user);
    const details: Record<string, unknown[]> = {};
    const detailsPagination: Record<string, { total: number; limit: number; nextOffset: number | null }> = {};
    const plan = context.artifact?.plan == null ? null : { ...asRecord(context.artifact.plan) };
    for (const kind of Object.keys(DETAIL_FIELDS) as DetailKind[]) {
      const page = await this.detailPage(context.artifact, kind, 0, PREVIEW_LIMIT);
      const field = DETAIL_FIELDS[kind];
      details[field] = page.items;
      detailsPagination[field] = { total: page.total, limit: PREVIEW_LIMIT, nextOffset: page.nextOffset };
      if (plan && context.artifact?.planFields.includes(field)) {
        plan[field] = (await this.reports.planPage(context.artifact.id, field, 0, PREVIEW_LIMIT))?.items ?? [];
      }
    }
    if (plan && context.artifact?.planFields.includes('userMappings')) {
      plan.userMappings = (await this.reports.planPage(context.artifact.id, 'userMappings', 0, PREVIEW_LIMIT))?.items ?? [];
    }
    if (plan) plan.previewPagination = detailsPagination;
    const summary = context.artifact?.summary == null ? null : { ...asRecord(context.artifact.summary) };
    if (summary && context.artifact?.hasSummaryPreview) summary.perUserPreview = details.userPreview;
    return { run: context.run, totals: context.totals, metrics: context.metrics, plan, summary, details, detailsPagination };
  }

  async getRunProgress(runId: number, user: RequestUser) {
    const run = await this.ownedRun(runId, user);
    const metrics = await this.repo.listRunMetrics(runId);
    return { run: sanitizeRunForApi(run), totals: summarizeMetrics(metrics), metrics };
  }

  async getRunDetails(runId: number, kind: string, offset = 0, limit = PREVIEW_LIMIT, user: RequestUser) {
    this.assertKind(kind);
    const context = await this.context(runId, user);
    return { runId, kind, ...(await this.detailPage(context.artifact, kind, this.offset(offset), this.limit(limit))) };
  }

  async getPlanMatches(artifactId: number, kind: string, offset = 0, limit = PREVIEW_LIMIT, user: RequestUser) {
    if (kind !== 'matched' && kind !== 'unresolved' && kind !== 'duplicate')
      throw new BadRequestException('Match kind must be matched, unresolved, or duplicate.');
    await this.ownedArtifact(artifactId, user);
    const boundedOffset = this.offset(offset);
    const boundedLimit = this.limit(limit);
    const page = await this.reports.planPage(artifactId, DETAIL_FIELDS[kind], boundedOffset, boundedLimit);
    return {
      artifactId,
      kind,
      offset: boundedOffset,
      limit: boundedLimit,
      total: page?.total ?? 0,
      nextOffset: nextOffset(boundedOffset, boundedLimit, page?.total ?? 0),
      items: page?.items ?? [],
    };
  }

  async getDuplicateCandidates(artifactId: number, targetBookId: number, offset = 0, limit = PREVIEW_LIMIT, user: RequestUser) {
    await this.ownedArtifact(artifactId, user);
    const group = await this.reports.duplicateGroup(artifactId, targetBookId);
    if (!group) throw new NotFoundException(`Duplicate match not found: ${targetBookId}`);
    const boundedOffset = this.offset(offset);
    const boundedLimit = this.limit(limit);
    const [ids, strategies, matches, existing] = await Promise.all([
      this.reports.duplicatePage(artifactId, targetBookId, 'sourceBookIds', boundedOffset, boundedLimit),
      this.reports.duplicatePage(artifactId, targetBookId, 'strategies', boundedOffset, boundedLimit),
      this.reports.duplicatePage(artifactId, targetBookId, 'matches', boundedOffset, boundedLimit),
      this.reports.duplicatePage(artifactId, targetBookId, 'sourceCandidates', boundedOffset, boundedLimit),
    ]);
    const sourceIds = ids.filter((id): id is string => typeof id === 'string');
    const books = await this.reports.sourceBooks(artifactId, sourceIds);
    const items = sourceIds.map((sourceBookId, index) => {
      const candidate = asRecord(existing[index]);
      const source = books.get(sourceBookId);
      return {
        sourceBookId,
        title: source?.title ?? candidate.title ?? null,
        author: source?.author ?? candidate.author ?? null,
        filePath: source?.filePath ?? candidate.filePath ?? null,
        strategy: asRecord(matches[index]).strategy ?? strategies[index] ?? candidate.strategy ?? 'title_author',
      };
    });
    return {
      artifactId,
      targetBookId,
      offset: boundedOffset,
      limit: boundedLimit,
      total: group.total,
      nextOffset: nextOffset(boundedOffset, boundedLimit, group.total),
      items,
    };
  }

  async exportRunReport(runId: number, requestedFormat: string | undefined, user: RequestUser) {
    const context = await this.context(runId, user);
    const format = requestedFormat?.toLowerCase() === 'csv' ? 'csv' : 'json';
    return {
      format,
      fileName: `migration-run-${runId}-report.${format}`,
      contentType: format === 'csv' ? 'text/csv; charset=utf-8' : 'application/json',
      content: Readable.from(this.loggedExport(runId, format, context)),
    };
  }

  private async *loggedExport(runId: number, format: string, context: Awaited<ReturnType<MigrationReportingService['context']>>) {
    const startedAt = Date.now();
    let bytes = 0;
    this.logger.log(`[migration.report_export] [start] runId=${runId} format=${format} - report export started`);
    try {
      for await (const chunk of format === 'csv' ? this.csvReport(context) : this.jsonReport(context)) {
        bytes += Buffer.byteLength(chunk);
        yield chunk;
      }
      this.logger.log(`[migration.report_export] [end] runId=${runId} durationMs=${Date.now() - startedAt} bytes=${bytes} - report export completed`);
    } catch (error) {
      this.logger.error(
        `[migration.report_export] [fail] runId=${runId} durationMs=${Date.now() - startedAt} errorClass=${error instanceof Error ? error.name : 'Unknown'} error="${sanitizeLogValue(error instanceof Error ? error.message : String(error))}" - report export failed`,
      );
      throw error;
    }
  }

  private async *jsonReport(context: Awaited<ReturnType<MigrationReportingService['context']>>) {
    yield `{"run":${JSON.stringify(context.run)},"totals":${JSON.stringify(context.totals)},"metrics":${JSON.stringify(context.metrics)},"plan":`;
    yield* this.artifactObject(context.artifact, 'plan');
    yield ',"summary":';
    yield* this.artifactObject(context.artifact, 'summary');
    yield ',"details":{';
    let first = true;
    for (const kind of Object.keys(DETAIL_FIELDS) as DetailKind[]) {
      yield `${first ? '' : ','}${JSON.stringify(DETAIL_FIELDS[kind])}:[`;
      first = false;
      let firstRow = true;
      for await (const row of this.detailRows(context.artifact, kind)) {
        if (!firstRow) yield ',';
        firstRow = false;
        if (kind === 'duplicate' && context.artifact) yield* this.duplicateDetail(context.artifact, asRecord(row));
        else yield JSON.stringify(row);
      }
      yield ']';
    }
    yield '}}';
  }

  private async *artifactObject(artifact: Artifact | null, kind: 'plan' | 'summary') {
    const base = artifact?.[kind];
    if (base == null || !artifact) {
      yield 'null';
      return;
    }
    const json = JSON.stringify(base);
    yield json.slice(0, -1);
    let hasFields = Object.keys(asRecord(base)).length > 0;
    const fields = kind === 'plan' ? artifact.planFields : artifact.hasSummaryPreview ? ['perUserPreview' as const] : [];
    for (const field of fields) {
      yield `${hasFields ? ',' : ''}${JSON.stringify(field)}:[`;
      hasFields = true;
      let first = true;
      for await (const row of this.planRows(artifact.id, field)) {
        if (!first) yield ',';
        first = false;
        if (field === 'duplicateBookMatches') yield* this.duplicatePlan(artifact.id, asRecord(row));
        else yield JSON.stringify(row);
      }
      yield ']';
    }
    yield '}';
  }

  private async *planRows(id: number, field: PlanArrayField | 'perUserPreview') {
    let offset = 0;
    while (true) {
      const page = await this.reports.planPage(id, field, offset, EXPORT_LIMIT);
      if (!page || page.items.length === 0) return;
      for (const row of page.items) yield row;
      offset += EXPORT_LIMIT;
      if (offset >= page.total) return;
    }
  }

  private async *duplicatePlan(id: number, preview: Record<string, unknown>) {
    const targetBookId = Number(preview.targetBookId);
    const group = await this.reports.duplicateGroup(id, targetBookId);
    if (!group) {
      yield JSON.stringify(preview);
      return;
    }
    yield JSON.stringify(group.base).slice(0, -1);
    let hasFields = Object.keys(group.base).length > 0;
    for (const field of group.fields as DuplicateArrayField[]) {
      yield `${hasFields ? ',' : ''}${JSON.stringify(field)}:[`;
      hasFields = true;
      yield* this.duplicateArray(id, targetBookId, field, group.total);
      yield ']';
    }
    yield '}';
  }

  private async *duplicateArray(id: number, targetBookId: number, field: DuplicateArrayField, total: number, titles = false) {
    let first = true;
    for (let offset = 0; offset < total; offset += EXPORT_LIMIT) {
      const page = await this.reports.duplicatePage(id, targetBookId, field, offset, EXPORT_LIMIT);
      const books = titles
        ? await this.reports.sourceBooks(
            id,
            page.filter((row): row is string => typeof row === 'string'),
          )
        : null;
      for (const row of page) {
        if (!first) yield ',';
        first = false;
        yield JSON.stringify(titles ? (books?.get(String(row))?.title ?? null) : row);
      }
    }
  }

  private async *duplicateDetail(artifact: Artifact, preview: Record<string, unknown>) {
    const targetBookId = Number(preview.targetBookId);
    const group = await this.reports.duplicateGroup(artifact.id, targetBookId);
    const total = group?.total ?? 0;
    yield `{"targetBookId":${targetBookId},"targetTitle":${JSON.stringify(preview.targetTitle ?? null)},"sourceBookIds":[`;
    yield* this.duplicateArray(artifact.id, targetBookId, 'sourceBookIds', total);
    yield '],"sourceTitles":[';
    yield* this.duplicateArray(artifact.id, targetBookId, 'sourceBookIds', total, true);
    yield '],"strategies":[';
    yield* this.duplicateArray(artifact.id, targetBookId, 'strategies', total);
    yield '],"reason":"duplicate_target_match"}';
  }

  private async *detailRows(artifact: Artifact | null, kind: DetailKind) {
    let offset = 0;
    while (true) {
      const page = await this.detailPage(artifact, kind, offset, EXPORT_LIMIT);
      for (const row of page.items) yield row;
      offset += EXPORT_LIMIT;
      if (offset >= page.total) return;
    }
  }

  private async *csvReport(context: Awaited<ReturnType<MigrationReportingService['context']>>) {
    const createdAt = (context.run.updatedAt ?? context.run.createdAt).toISOString();
    const counts: Partial<Record<DetailKind, number>> = {};
    for (const kind of ['matched', 'unresolved', 'users'] as const) counts[kind] = (await this.detailPage(context.artifact, kind, 0, 1)).total;
    yield `${CSV_HEADERS.join(',')}\n`;
    yield csvLine({
      section: 'summary',
      ...context.totals,
      details: `matchedBooks=${counts.matched}; unresolvedBooks=${counts.unresolved}; mappedUsers=${counts.users}`,
      code: 'summary',
      message: `Run state: ${context.run.state}`,
      createdAt,
    });
    for (const metric of context.metrics)
      yield csvLine({
        section: 'metrics',
        stage: metric.stage,
        entityType: metric.entityType,
        processed: metric.processed,
        imported: metric.imported,
        skipped: metric.skipped,
        unresolved: metric.unresolved,
        failed: metric.failed,
        createdAt: metric.updatedAt.toISOString(),
      });
    for (const kind of Object.keys(DETAIL_FIELDS) as DetailKind[]) {
      for await (const value of this.detailRows(context.artifact, kind)) {
        const row = asRecord(value);
        if (kind === 'matched')
          yield csvLine({ section: 'matched_books', stage: 'shared_overlays', entityType: 'book_match', ...row, createdAt } as CsvRow);
        else if (kind === 'unresolved')
          yield csvLine({
            section: 'unresolved_books',
            entityType: 'book_match',
            sourceBookId: String(row.sourceBookId),
            sourceTitle: row.title as string | null,
            sourceAuthor: row.author as string | null,
            reason: String(row.reason),
            createdAt,
          });
        else if (kind === 'users') {
          const counts = asRecord(row.counts);
          yield csvLine({
            section: 'user_preview',
            stage: 'user_state',
            entityType: 'user_preview',
            sourceUserId: String(row.sourceUserId),
            targetUserId: Number(row.targetUserId),
            username: String(row.username),
            details: `statuses=${String(counts.statuses)}; fileProgress=${String(counts.fileProgress)}; readingSessions=${String(counts.readingSessions)}; bookmarks=${String(counts.bookmarks)}; annotations=${String(counts.annotations)}; shelves=${String(counts.shelves)}`,
            createdAt,
          });
        } else if (context.artifact) yield* this.duplicateCsv(context.artifact, row, createdAt);
      }
    }
  }

  private async *duplicateCsv(artifact: Artifact, row: Record<string, unknown>, createdAt: string) {
    const targetBookId = Number(row.targetBookId);
    const group = await this.reports.duplicateGroup(artifact.id, targetBookId);
    const total = group?.total ?? 0;
    const base: CsvRow = {
      section: 'duplicate_matches',
      entityType: 'book_match',
      targetBookId,
      targetTitle: row.targetTitle as string | null,
      reason: 'duplicate_target_match',
      createdAt,
    };
    for (let index = 0; index < CSV_HEADERS.length; index += 1) {
      if (index) yield ',';
      const field = CSV_HEADERS[index];
      if (['sourceBookId', 'sourceTitle', 'strategy', 'details'].includes(field)) {
        yield '"';
        if (field === 'details') yield 'sourceBookIds=';
        let first = true;
        for (let offset = 0; offset < total; offset += EXPORT_LIMIT) {
          const values = await this.reports.duplicatePage(
            artifact.id,
            targetBookId,
            field === 'strategy' ? 'strategies' : 'sourceBookIds',
            offset,
            EXPORT_LIMIT,
          );
          const books =
            field === 'sourceTitle'
              ? await this.reports.sourceBooks(
                  artifact.id,
                  values.filter((v): v is string => typeof v === 'string'),
                )
              : null;
          for (const value of values) {
            const text = field === 'sourceTitle' ? books?.get(String(value))?.title : String(value);
            if (text == null) continue;
            if (!first) yield field === 'sourceTitle' ? ' | ' : '|';
            first = false;
            yield text.replace(/"/g, '""');
          }
        }
        yield '"';
      } else yield csvCell(base[field]);
    }
    yield '\n';
  }

  private async detailPage(artifact: Artifact | null, kind: DetailKind, offset: number, limit: number) {
    const field = kind === 'users' && !artifact?.hasUserPreview ? 'perUserPreview' : DETAIL_FIELDS[kind];
    const page = artifact ? await this.reports.planPage(artifact.id, field, offset, limit) : null;
    const raw = page?.items ?? [];
    const sourceIds = raw.flatMap((value) => {
      const row = asRecord(value);
      return typeof row.sourceBookId === 'string'
        ? [row.sourceBookId]
        : Array.isArray(row.sourceBookIds)
          ? row.sourceBookIds.filter((id): id is string => typeof id === 'string')
          : [];
    });
    const targetIds = raw.flatMap((value) => (typeof asRecord(value).targetBookId === 'number' ? [Number(asRecord(value).targetBookId)] : []));
    const [books, titles] = await Promise.all([
      artifact ? this.reports.sourceBooks(artifact.id, sourceIds) : Promise.resolve(new Map()),
      this.repo.findBookTitlesByIds(uniqueNumbers(targetIds)),
    ]);
    let items: unknown[];
    if (kind === 'matched')
      items = normalizeMatchedBooks(raw).map((row) => ({
        ...row,
        sourceTitle: books.get(row.sourceBookId)?.title ?? null,
        sourceAuthor: books.get(row.sourceBookId)?.author ?? null,
        targetTitle: titles.get(row.targetBookId) ?? null,
      }));
    else if (kind === 'unresolved') items = normalizeUnresolvedBooks(raw, books);
    else if (kind === 'duplicate')
      items = normalizeDuplicateBookMatches(raw).map((row, index) => ({
        targetBookId: row.targetBookId,
        targetTitle: titles.get(row.targetBookId) ?? null,
        sourceBookIds: row.sourceBookIds,
        sourceTitles: row.sourceBookIds.map((id) => books.get(id)?.title ?? null),
        strategies: row.strategies,
        reason: row.reason,
        candidatePagination: asRecord(raw[index]).candidatePagination,
      }));
    else items = normalizeUserPreview(raw, []);
    const total = page?.total ?? 0;
    return { offset, limit, total, nextOffset: nextOffset(offset, limit, total), items };
  }

  private async ownedRun(runId: number, user: RequestUser) {
    const run = await this.repo.findRunById(runId);
    if (!run) throw new NotFoundException(`Migration run not found: ${runId}`);
    if (!user.isSuperuser && run.triggeredByUserId !== user.id) throw new ForbiddenException('Migration belongs to another user');
    return run;
  }

  private async ownedArtifact(id: number, user: RequestUser) {
    const artifact = await this.reports.findArtifact(id);
    if (!artifact) throw new NotFoundException(`Migration plan artifact not found: ${id}`);
    if (!user.isSuperuser && artifact.createdByUserId !== user.id) throw new ForbiddenException('Migration belongs to another user');
    return artifact;
  }

  private async context(runId: number, user: RequestUser) {
    const run = await this.ownedRun(runId, user);
    const [metrics, artifact] = await Promise.all([
      this.repo.listRunMetrics(runId),
      run.planArtifactId ? this.ownedArtifact(run.planArtifactId, user) : Promise.resolve(null),
    ]);
    return { run: sanitizeRunForApi(run), metrics, totals: summarizeMetrics(metrics), artifact };
  }

  private assertKind(kind: string): asserts kind is DetailKind {
    if (!Object.hasOwn(DETAIL_FIELDS, kind)) throw new BadRequestException('Detail kind must be matched, unresolved, duplicate, or users.');
  }
  private limit(limit: number) {
    return Math.min(Math.max(Math.trunc(limit), 1), EXPORT_LIMIT);
  }
  private offset(offset: number) {
    return Math.max(Math.trunc(offset), 0);
  }
}

function nextOffset(offset: number, limit: number, total: number) {
  return offset + limit < total ? offset + limit : null;
}
function csvLine(row: CsvRow) {
  return `${CSV_HEADERS.map((field) => csvCell(row[field])).join(',')}\n`;
}
function csvCell(value: string | number | null | undefined): string {
  if (value == null) return '';
  const text = String(value);
  return /[",\n\r]/.test(text) ? `"${text.replace(/"/g, '""')}"` : text;
}

function summarizeMetrics(metrics: Array<{ processed: number; imported: number; skipped: number; unresolved: number; failed: number }>) {
  return metrics.reduce(
    (acc, row) => ({
      processed: acc.processed + row.processed,
      imported: acc.imported + row.imported,
      skipped: acc.skipped + row.skipped,
      unresolved: acc.unresolved + row.unresolved,
      failed: acc.failed + row.failed,
    }),
    {
      processed: 0,
      imported: 0,
      skipped: 0,
      unresolved: 0,
      failed: 0,
    },
  );
}

function normalizeMatchedBooks(value: unknown): PlannedBookMatch[] {
  if (!Array.isArray(value)) return [];
  return value.flatMap((row) => {
    const record = asRecord(row);
    const sourceBookId = typeof record.sourceBookId === 'string' ? record.sourceBookId : null;
    const targetBookId = typeof record.targetBookId === 'number' ? record.targetBookId : null;
    const strategy = typeof record.strategy === 'string' ? record.strategy : null;
    if (!sourceBookId || targetBookId == null || !strategy) return [];
    return [{ sourceBookId, targetBookId, strategy: strategy as PlannedBookMatch['strategy'] }];
  });
}

function normalizeUnresolvedBooks(
  value: unknown,
  sourceBooksById: Map<string, Pick<SourceBook, 'title' | 'author'>>,
): Array<{ sourceBookId: string; title: string | null; author: string | null; reason: string }> {
  if (!Array.isArray(value)) return [];
  return value.flatMap((row) => {
    const record = asRecord(row);
    const sourceBookId = typeof record.sourceBookId === 'string' ? record.sourceBookId : null;
    const reason = typeof record.reason === 'string' ? record.reason : null;
    if (!sourceBookId || !reason) return [];
    const sourceBook = sourceBooksById.get(sourceBookId);
    return [
      {
        sourceBookId,
        title: (typeof record.title === 'string' ? record.title : null) ?? sourceBook?.title ?? null,
        author: sourceBook?.author ?? null,
        reason,
      },
    ];
  });
}

function normalizeDuplicateBookMatches(value: unknown): PlannedDuplicateBookMatch[] {
  if (!Array.isArray(value)) return [];
  return value.flatMap((row) => {
    const record = asRecord(row);
    const targetBookId = typeof record.targetBookId === 'number' ? record.targetBookId : null;
    const sourceBookIds = Array.isArray(record.sourceBookIds) ? record.sourceBookIds.filter((id): id is string => typeof id === 'string') : [];
    const strategies = Array.isArray(record.strategies)
      ? record.strategies.filter((strategy): strategy is PlannedBookMatch['strategy'] => typeof strategy === 'string')
      : [];
    if (targetBookId == null || sourceBookIds.length === 0) return [];
    return [
      {
        targetBookId,
        sourceBookIds,
        matches: sourceBookIds.map((sourceBookId, index) => ({
          sourceBookId,
          targetBookId,
          strategy: strategies[index] ?? 'title_author',
        })),
        strategies,
        reason: 'duplicate_target_match',
      } satisfies PlannedDuplicateBookMatch,
    ];
  });
}

function normalizeUserPreview(planValue: unknown, summaryValue: unknown): PlannedUserPreview[] {
  const rows = Array.isArray(planValue) ? planValue : Array.isArray(summaryValue) ? summaryValue : [];
  return rows.flatMap((row) => {
    const record = asRecord(row);
    const counts = asRecord(record.counts);
    const sourceUserId = typeof record.sourceUserId === 'string' ? record.sourceUserId : null;
    const targetUserId = typeof record.targetUserId === 'number' ? record.targetUserId : null;
    const username = typeof record.username === 'string' ? record.username : null;
    if (!sourceUserId || targetUserId == null || !username) return [];
    return [
      {
        sourceUserId,
        targetUserId,
        username,
        counts: {
          statuses: typeof counts.statuses === 'number' ? counts.statuses : 0,
          fileProgress: typeof counts.fileProgress === 'number' ? counts.fileProgress : 0,
          readingSessions: typeof counts.readingSessions === 'number' ? counts.readingSessions : 0,
          bookmarks: typeof counts.bookmarks === 'number' ? counts.bookmarks : 0,
          annotations: typeof counts.annotations === 'number' ? counts.annotations : 0,
          shelves: typeof counts.shelves === 'number' ? counts.shelves : 0,
        },
      },
    ];
  });
}

function uniqueNumbers(values: number[]): number[] {
  return [...new Set(values.filter((value) => Number.isFinite(value)))];
}
