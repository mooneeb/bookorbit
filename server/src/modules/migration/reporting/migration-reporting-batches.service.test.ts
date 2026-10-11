import { Readable } from 'node:stream';
import { BadRequestException } from '@nestjs/common';
import { Test, type TestingModule } from '@nestjs/testing';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

import type { RequestUser } from '../../../common/types/request-user';
import { MigrationRepository } from '../migration.repository';
import { MigrationReportRepository, type DuplicateArrayField, type PlanArrayField } from './migration-report.repository';
import { MigrationReportingService } from './migration-reporting.service';

const owner = { id: 9, isSuperuser: false } as RequestUser;
const artifactId = 99;
const date = new Date('2026-01-01T00:00:00.000Z');

function duplicateGroups(count: number, candidates: number) {
  return Array.from({ length: count }, (_, index) => ({
    targetBookId: index + 1,
    sourceBookIds: Array.from({ length: candidates }, (_, candidate) => `source-${index}-${candidate}`),
    strategies: Array.from({ length: candidates }, () => 'isbn'),
    candidatePagination: { total: candidates, limit: 40, nextOffset: null },
  }));
}

async function readStream(stream: Readable) {
  let text = '';
  for await (const chunk of stream) text += String(chunk);
  return text;
}

describe('migration report page metadata batches', () => {
  let module: TestingModule;
  let service: MigrationReportingService;
  let groups: ReturnType<typeof duplicateGroups>;
  const sourceBooks = vi.fn((_id: number, ids: string[]) => {
    if (ids.length > 100) throw new BadRequestException('Metadata batch exceeds 100');
    return new Map(ids.map((id) => [id, { title: `Title ${id}`, author: `Author ${id}`, filePath: null }]));
  });
  const planPage = vi.fn((_id: number, field: PlanArrayField | 'perUserPreview', offset: number, limit: number) => ({
    total: field === 'duplicateBookMatches' ? groups.length : 0,
    items: field === 'duplicateBookMatches' ? groups.slice(offset, offset + limit) : [],
  }));

  beforeEach(async () => {
    vi.clearAllMocks();
    groups = [];
    module = await Test.createTestingModule({
      providers: [
        MigrationReportingService,
        {
          provide: MigrationRepository,
          useValue: {
            findRunById: vi.fn().mockResolvedValue({
              id: 7,
              planArtifactId: artifactId,
              triggeredByUserId: owner.id,
              state: 'completed',
              createdAt: date,
              updatedAt: date,
            }),
            listRunMetrics: vi.fn().mockResolvedValue([{ processed: 102, imported: 80, skipped: 22, unresolved: 0, failed: 0, updatedAt: date }]),
            findBookTitlesByIds: vi.fn((ids: number[]) => new Map(ids.map((id) => [id, `Target ${id}`]))),
          },
        },
        {
          provide: MigrationReportRepository,
          useValue: {
            findArtifact: vi.fn().mockResolvedValue({
              id: artifactId,
              createdByUserId: owner.id,
              plan: {},
              summary: {},
              planFields: ['duplicateBookMatches'],
              hasUserPreview: true,
              hasSummaryPreview: false,
            }),
            planPage,
            sourceBooks,
            duplicateGroup: vi.fn((_id: number, targetId: number) => {
              const group = groups.find((row) => row.targetBookId === targetId)!;
              return { base: { targetBookId: targetId }, total: group.sourceBookIds.length, fields: ['sourceBookIds', 'strategies'] };
            }),
            duplicatePage: vi.fn((_id: number, targetId: number, field: DuplicateArrayField, offset: number, limit: number) => {
              const group = groups.find((row) => row.targetBookId === targetId)!;
              const values = field === 'sourceBookIds' ? group.sourceBookIds : field === 'strategies' ? group.strategies : [];
              return values.slice(offset, offset + limit);
            }),
          },
        },
      ],
    }).compile();
    service = module.get(MigrationReportingService);
  });

  afterEach(async () => {
    await module.close();
  });

  function expectBoundedLookups() {
    expect(sourceBooks.mock.calls.length).toBeGreaterThan(0);
    for (const [id, ids] of sourceBooks.mock.calls) {
      expect(id).toBe(artifactId);
      expect(ids.length).toBeLessThanOrEqual(100);
      expect(new Set(ids).size).toBe(ids.length);
    }
  }

  it('hydrates 34 duplicate preview groups with 102 candidates and preserves totals', async () => {
    groups = duplicateGroups(34, 3);
    const report = await service.getRunReport(7, owner);
    expect(report.details.duplicateBookMatches).toHaveLength(34);
    expect(report.details.duplicateBookMatches[33]).toMatchObject({
      targetTitle: 'Target 34',
      sourceTitles: groups[33].sourceBookIds.map((id) => `Title ${id}`),
    });
    expect(report.detailsPagination.duplicateBookMatches).toEqual({ total: 34, limit: 40, nextOffset: null });
    expect(report.totals).toEqual({ processed: 102, imported: 80, skipped: 22, unresolved: 0, failed: 0 });
    expect(sourceBooks.mock.calls.map(([, ids]) => ids.length)).toEqual([100, 2]);
    expectBoundedLookups();
  });

  it('hydrates a requested 100-group detail page and deduplicates repeated candidates', async () => {
    groups = duplicateGroups(60, 2);
    groups[59].sourceBookIds[1] = groups[0].sourceBookIds[0];
    const page = await service.getRunDetails(7, 'duplicate', 0, 100, owner);
    expect(page).toMatchObject({ total: 60, limit: 100, nextOffset: null });
    expect(page.items).toHaveLength(60);
    expect(page.items[59]).toMatchObject({ sourceTitles: groups[59].sourceBookIds.map((id) => `Title ${id}`) });
    expect(sourceBooks.mock.calls.map(([, ids]) => ids.length)).toEqual([100, 19]);
    expectBoundedLookups();
  });

  it('completes JSON and CSV streams with more than 100 nested candidates across export pages', async () => {
    groups = duplicateGroups(101, 2);
    const json = JSON.parse(await readStream((await service.exportRunReport(7, 'json', owner)).content));
    expect(json.details.duplicateBookMatches).toHaveLength(101);
    expect(json.plan.duplicateBookMatches).toHaveLength(101);
    expect(json.details.duplicateBookMatches[100]).toMatchObject({
      targetBookId: 101,
      sourceTitles: groups[100].sourceBookIds.map((id) => `Title ${id}`),
    });
    const csv = await readStream((await service.exportRunReport(7, 'csv', owner)).content);
    const rows = csv
      .trimEnd()
      .split('\n')
      .filter((row) => row.startsWith('duplicate_matches,'));
    expect(rows).toHaveLength(101);
    expect(rows[100]).toContain('source-100-0|source-100-1');
    expect(rows[100]).toContain('Title source-100-0 | Title source-100-1');
    expect(planPage.mock.calls.some(([, field, offset]) => field === 'duplicateBookMatches' && offset === 100)).toBe(true);
    expectBoundedLookups();
  });
});
