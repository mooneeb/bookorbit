import { BadRequestException, ForbiddenException, Logger, NotFoundException } from '@nestjs/common';
import { Test } from '@nestjs/testing';
import type { NativeAnnotationItem, NativeAnnotationOperation, NativeAnnotationOperationsRequest } from '@bookorbit/types';
import { drizzle } from 'drizzle-orm/node-postgres';
import { DB } from '../../db';
import * as schema from '../../db/schema';
import type { RequestUser } from '../../common/types/request-user';
import { NativeAnnotationHubService } from './native-annotation-hub.service';
import { NativeAnnotationService } from './native-annotation.service';

const actor = { id: 7 } as RequestUser;
const item = (id: number, extra: Partial<NativeAnnotationItem> = {}) => ({ id, kind: 'highlight', version: 3, ...extra }) as NativeAnnotationItem;
const operation = (extra: Partial<NativeAnnotationOperation> = {}): NativeAnnotationOperation => ({
  operationId: 'd7e2d3d0-a60d-4f0f-9271-5c35dfd7e7c5',
  clientId: 'a07d242a-5a53-4cb1-a79d-0d7394459af1',
  annotationId: 9,
  bookId: 4,
  baseVersion: 3,
  action: 'delete',
  ...extra,
});
const request = (operations = [operation()]): NativeAnnotationOperationsRequest => ({ deviceId: 'reader-tablet', operations });
const row = (id: number, group: string | number = '') => [id, 'Book', 'Writer', 'PDF', group];
const createdAt = '2026-10-01T00:00:00.000Z';

async function harness(pages: unknown[][][] = []) {
  const query = vi.fn<(...args: unknown[]) => Promise<{ rows: unknown[][] }>>(() => Promise.resolve({ rows: pages.shift() ?? [] }));
  const db = drizzle({ client: { query } as never, schema });
  const native = {
    getItems: vi.fn<(ids: number[], userId: number) => Promise<NativeAnnotationItem[]>>((ids) => Promise.resolve(ids.map((id) => item(id)))),
    getItem: vi.fn().mockResolvedValue(item(9)),
    recoverySnapshots: vi.fn().mockResolvedValue(new Map()),
    operations: vi.fn().mockResolvedValue({ results: [] }),
  };
  const module = await Test.createTestingModule({
    providers: [NativeAnnotationHubService, { provide: DB, useValue: db }, { provide: NativeAnnotationService, useValue: native }],
  }).compile();
  return { service: module.get(NativeAnnotationHubService), query, native };
}
function sqlCall(query: ReturnType<typeof vi.fn>, index = 0) {
  const [config, params] = query.mock.calls[index] as [{ text: string }, unknown[]];
  return { sql: config.text, params };
}

describe('NativeAnnotationHubService user-owned bounded operations', () => {
  beforeEach(() => {
    vi.spyOn(Logger.prototype, 'log').mockImplementation(() => undefined);
    vi.spyOn(Logger.prototype, 'error').mockImplementation(() => undefined);
  });
  afterEach(() => vi.restoreAllMocks());

  it('fetches one bounded page and hydrates only visible rows for the current user', async () => {
    const { service, query, native } = await harness([[row(12), row(11), row(10)]]);
    native.getItems.mockResolvedValue([item(12)]);
    expect(await service.list(7, { limit: 2 })).toEqual({
      items: [{ ...item(12), bookTitle: 'Book', author: 'Writer', fileFormat: 'PDF', groupKey: '' }],
      nextCursor: 11,
    });
    expect(native.getItems).toHaveBeenCalledExactlyOnceWith([12, 11], 7);
    const call = sqlCall(query);
    expect(call.sql).toContain('"annotations"."user_id" = $1');
    expect(call.sql).toContain('"annotations"."deleted_at" is null');
    expect(call.sql).toContain('order by "annotations"."id" desc limit');
    expect(call.params).toEqual([7, 3]);
  });

  it.each(['book', 'month', 'kind', 'source'] as const)('uses deterministic %s grouping with a user-scoped cursor', async (groupBy) => {
    const { service, query } = await harness([[[20, groupBy === 'book' ? 4 : 'group']], [row(19, 'group')]]);
    expect((await service.list(7, { groupBy, cursor: 20, limit: 1 })).nextCursor).toBeNull();
    const cursorCall = sqlCall(query);
    expect(cursorCall.sql).toContain('"annotations"."user_id" = $1');
    expect(cursorCall.params).toEqual([7, 20, 1]);
    const call = sqlCall(query, 1);
    expect(call.sql).toContain(groupBy === 'month' ? '<' : '>');
    expect(call.sql).toContain('"annotations"."id" <');
    expect(call.sql).toContain('"annotations"."id" desc');
  });

  it('rejects unavailable or foreign cursors before fetching any annotation page', async () => {
    const { service, query, native } = await harness([[]]);
    await expect(service.list(7, { cursor: 88 })).rejects.toBeInstanceOf(BadRequestException);
    expect(query).toHaveBeenCalledTimes(1);
    expect(native.getItems).not.toHaveBeenCalled();
  });

  it('scopes recovery and file subqueries and escapes search wildcard characters', async () => {
    const { service, query } = await harness([[]]);
    await service.list(7, { status: 'recovery', bookId: 4, fileId: 5, kind: 'pdf_ink', search: 'ink%_\\' });
    const call = sqlCall(query);
    expect(call.sql).toContain('exists (select');
    expect(call.sql).toContain('"native_annotation_drafts"."user_id"');
    expect(call.sql).toContain('"annotation_positions"."user_id"');
    expect(call.params.filter((value) => value === 7)).toHaveLength(3);
    expect(call.params).toContain('%ink\\%\\_\\\\%');
    expect(call.params).toContain(41);
  });

  it('supports descending ungrouped continuation and explicit trash filtering', async () => {
    const { service, query } = await harness([[[20, '']], []]);
    await service.list(7, { status: 'trashed', cursor: 20 });
    expect(sqlCall(query, 1).sql).toContain('"annotations"."deleted_at" is not null');
    expect(sqlCall(query, 1).params).toEqual([7, 20, 41]);
  });

  it('exports a deduplicated owned selection with canonical source ink preserved', async () => {
    const drawing = { format: 'bookorbit-ink-v1' as const, strokes: [], nativeData: 'retained-source-ink' };
    const { service, query, native } = await harness([[row(9)]]);
    native.getItems.mockResolvedValue([item(9, { kind: 'pdf_ink', drawing })]);
    const result = await service.export(7, { ids: [9, 9] });
    expect(result.contentType).toBe('application/json; charset=utf-8');
    expect(result.filename).toBe('bookorbit-annotations.json');
    expect(JSON.parse(result.content)).toEqual({
      format: 'bookorbit-annotations-v1',
      items: [{ ...item(9, { kind: 'pdf_ink', drawing }), bookTitle: 'Book', author: 'Writer', fileFormat: 'PDF', groupKey: '' }],
      nextCursor: null,
    });
    expect(sqlCall(query).params).toEqual([7, 9, 100]);
  });

  it('denies exports containing missing or foreign selections before hydration', async () => {
    const { service, native } = await harness([[row(9)]]);
    await expect(service.export(7, { ids: [9, 88] })).rejects.toBeInstanceOf(ForbiddenException);
    expect(native.getItems).not.toHaveBeenCalled();
    expect(Logger.prototype.error).toHaveBeenCalledWith(expect.stringContaining('[annotation.native_export] [fail] userId=7'));
  });

  it('exports a bounded recovery page with independent retained drafts', async () => {
    const { service } = await harness([[row(9)], [[2, 4, 9, 'op', 'conflict', operation(), createdAt, item(9), null, 'highlight']]]);
    const result = JSON.parse((await service.export(7, { status: 'recovery', limit: 1 })).content);
    expect(result.items).toHaveLength(1);
    expect(result.drafts).toEqual([expect.objectContaining({ id: 2, snapshot: item(9), createdAt })]);
    expect(result.nextDraftCursor).toBeNull();
  });

  it('paginates drafts and recovers only missing snapshots without mutating retained payloads', async () => {
    const payload = operation({
      annotationId: undefined,
      payload: { kind: 'pdf_ink', drawing: { format: 'bookorbit-ink-v1', strokes: [], nativeData: 'source' } },
    });
    const { service, query, native } = await harness([
      [
        [8, 4, 9, 'stored', 'conflict', operation(), createdAt, item(9), null, 'highlight'],
        [7, 4, 10, 'missing', 'stale', payload, createdAt, null, null, 'pdf_ink'],
        [6, 4, 11, 'next', 'stale', operation(), createdAt, null, null, 'pdf_ink'],
      ],
    ]);
    native.recoverySnapshots.mockResolvedValue(new Map([['missing', item(10, { kind: 'pdf_ink', drawing: payload.payload!.drawing! })]]));
    const result = await service.drafts(7, { limit: 2, cursor: 9, bookId: 4, fileId: 5, kind: 'pdf_ink', search: 'text%' }, [9, 10]);
    expect(result.nextCursor).toBe(7);
    expect(result.items[0].snapshot).toEqual(item(9));
    expect(result.items[1].snapshot?.drawing?.nativeData).toBe('source');
    expect(result.items[1].payload).toEqual(payload);
    expect(native.recoverySnapshots).toHaveBeenCalledExactlyOnceWith(7, [{ ...payload, annotationId: 10 }], ['missing']);
    const call = sqlCall(query);
    expect(call.sql).toContain('"native_annotation_drafts"."user_id" =');
    expect(call.sql).toContain('order by "native_annotation_drafts"."id" desc limit');
    expect(call.params).toContain('%text\\%%');
    expect(call.params.at(-1)).toBe(3);
  });

  it('reports explicit and default snapshot unavailability without dropping drafts', async () => {
    const { service, native } = await harness([
      [
        [3, 4, null, 'one', 'conflict', operation(), createdAt, null, 'source_removed', 'highlight'],
        [2, 4, null, 'two', 'conflict', operation(), createdAt, null, null, 'highlight'],
      ],
    ]);
    const result = await service.drafts(7, {});
    expect(result.items.map((draft) => draft.snapshotUnavailableReason)).toEqual(['source_removed', 'retained_base_unavailable']);
    expect(native.recoverySnapshots).toHaveBeenCalledWith(7, [operation(), operation()], []);
    expect(result.nextCursor).toBeNull();
  });

  it('paginates device acknowledgements with a composite stable cursor', async () => {
    const { service, query } = await harness([
      [
        ['tablet', 4, '123', createdAt],
        ['tablet', 5, '124', createdAt],
      ],
    ]);
    const result = await service.devices(7, { limit: 1, bookId: 4 });
    expect(result.items).toEqual([{ deviceId: 'tablet', bookId: 4, cursor: 123, updatedAt: createdAt }]);
    expect(JSON.parse(Buffer.from(result.nextCursor!, 'base64url').toString())).toEqual({ deviceId: 'tablet', bookId: 4 });
    await service.devices(7, { cursor: result.nextCursor! });
    expect(sqlCall(query).params).toEqual([7, 4, 2]);
    expect(sqlCall(query, 1).params).toEqual([7, 'tablet', 'tablet', 4, 41]);
    expect(sqlCall(query, 1).sql).toContain('order by "native_annotation_acks"."device_id" asc, "native_annotation_acks"."book_id" asc');
  });

  it.each([
    'invalid',
    Buffer.from('null').toString('base64url'),
    ...[
      { deviceId: '', bookId: 4 },
      { deviceId: 'x'.repeat(101), bookId: 4 },
      { deviceId: 'tablet', bookId: 0 },
      { deviceId: 'tablet', bookId: 1.2 },
      { deviceId: 'tablet', bookId: '4' },
    ].map((value) => Buffer.from(JSON.stringify(value)).toString('base64url')),
  ])('rejects malformed device cursor %s before database access', async (cursor) => {
    const { service, query } = await harness();
    await expect(service.devices(7, { cursor })).rejects.toBeInstanceOf(BadRequestException);
    expect(query).not.toHaveBeenCalled();
  });

  it('forwards delete and restore revisions once and preserves applied, recovery and conflict outcomes', async () => {
    const { service, native } = await harness();
    const input = request([operation(), operation({ action: 'restore', baseVersion: 2 })]);
    const result = {
      results: [
        { operationId: 'one', status: 'applied' },
        { operationId: 'two', status: 'recovery', draftId: 3 },
        { operationId: 'three', status: 'conflict', annotation: item(9) },
      ],
    };
    native.operations.mockResolvedValue(result);
    expect(await service.bulk(actor, input)).toBe(result);
    expect(native.operations).toHaveBeenCalledExactlyOnceWith(actor, input);
    expect(Logger.prototype.log).toHaveBeenCalledWith(expect.stringContaining('applied=1 recovery=1 conflicts=1'));
  });

  it.each([[], [operation({ action: 'create' })], [operation(), operation({ action: 'update' })]].map((operations) => ({ operations })))(
    'rejects invalid bulk action collections before mutation',
    async ({ operations }) => {
      const { service, native } = await harness();
      await expect(service.bulk(actor, request(operations))).rejects.toBeInstanceOf(BadRequestException);
      expect(native.operations).not.toHaveBeenCalled();
    },
  );

  it('checks repair ownership and preserves revision and source recovery payload', async () => {
    const { service, native } = await harness();
    const input = request([operation({ action: 'repair', payload: { sourceRevision: 'source-r2', pageFingerprint: 'page' } })]);
    await service.repair(actor, 9, input);
    expect(native.getItem).toHaveBeenCalledExactlyOnceWith(9, 7);
    expect(native.operations).toHaveBeenCalledExactlyOnceWith(actor, input);
  });

  it('rejects a repair for an inaccessible annotation before mutation', async () => {
    const { service, native } = await harness();
    native.getItem.mockResolvedValue(null);
    await expect(service.repair(actor, 9, request([operation({ action: 'repair' })]))).rejects.toBeInstanceOf(NotFoundException);
    expect(native.operations).not.toHaveBeenCalled();
  });

  it.each(
    [[], [operation()], [operation({ action: 'repair', annotationId: 10 })], [operation({ action: 'repair' }), operation({ action: 'repair' })]].map(
      (operations) => ({ operations }),
    ),
  )('requires exactly one explicit matching repair operation', async ({ operations }) => {
    const { service, native } = await harness();
    await expect(service.repair(actor, 9, request(operations))).rejects.toBeInstanceOf(BadRequestException);
    expect(native.getItem).not.toHaveBeenCalled();
    expect(native.operations).not.toHaveBeenCalled();
  });

  it.each([new BadRequestException('bad "revision"\npath\\file'), 'unknown failure'])(
    'propagates mutation failure and logs a sanitized single line',
    async (failure) => {
      const { service, native } = await harness();
      native.operations.mockRejectedValue(failure);
      await expect(service.bulk(actor, request())).rejects.toBe(failure);
      const message = vi.mocked(Logger.prototype.error).mock.calls[0][0] as string;
      expect(message).toContain('[annotation.native_bulk] [fail] userId=7');
      expect(message).not.toContain('\n');
      expect(message).toContain(failure instanceof Error ? 'errorClass=BadRequestException' : 'errorClass=UnknownError');
    },
  );
});
