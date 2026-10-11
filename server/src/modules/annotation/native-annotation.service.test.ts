import { BadRequestException, ConflictException, ForbiddenException, Logger, NotFoundException } from '@nestjs/common';
import { Test } from '@nestjs/testing';
import { Permission, type NativeAnnotationItem, type NativeAnnotationOperation } from '@bookorbit/types';
import { getTableColumns, type Table } from 'drizzle-orm';
import { drizzle } from 'drizzle-orm/node-postgres';
import { DB } from '../../db';
import * as schema from '../../db/schema';
import type { RequestUser } from '../../common/types/request-user';
import { BookService } from '../book/book.service';
import { NATIVE_INK_PUBLISHER, NativeAnnotationService } from './native-annotation.service';

const user = { id: 7, isSuperuser: false, permissions: [Permission.LibraryEditMetadata] } as RequestUser;
const now = new Date('2026-10-01T00:00:00Z');
const clientId = '7d2bcd62-aa64-4a39-b69f-4e2ef63c39bd';
const pdf = { page: 2, rect: { x: 1, y: 2, width: 3, height: 4 }, rects: [{ x: 1, y: 2, width: 3, height: 4 }] };
const drawing = {
  format: 'bookorbit-ink-v1' as const,
  strokes: [{ id: 'stroke-1', points: [{ x: 3, y: 4, pressure: 0.5 }], color: '#123456', width: 2 }],
};
function annotation(overrides: Partial<typeof schema.annotations.$inferSelect> = {}): typeof schema.annotations.$inferSelect {
  return {
    id: 20,
    clientId,
    kind: 'highlight',
    drawing: null,
    sourceRevision: null,
    pageFingerprint: null,
    changeSequence: 15,
    userId: 7,
    bookId: 9,
    text: 'passage',
    color: 'yellow',
    style: 'highlight',
    note: 'private note',
    chapterTitle: 'Chapter',
    origin: 'web',
    version: 1,
    deletedAt: null,
    deviceCreatedAt: null,
    deviceUpdatedAt: null,
    sourceCreatedAt: null,
    starredAt: now,
    createdAt: now,
    updatedAt: now,
    ...overrides,
  };
}
function position(overrides: Partial<typeof schema.annotationPositions.$inferSelect> = {}): typeof schema.annotationPositions.$inferSelect {
  return {
    id: 30,
    annotationId: 20,
    userId: 7,
    bookFileId: 10,
    format: 'cfi',
    pos0: 'epubcfi(/6/4)',
    pos1: null,
    status: 'exact',
    converterVersion: null,
    extras: { chapterIndex: 3 },
    createdAt: now,
    updatedAt: now,
    ...overrides,
  };
}
function values(table: Table, row: object): unknown[] {
  return Object.keys(getTableColumns(table)).map((key) => {
    const value = (row as Record<string, unknown>)[key];
    return value instanceof Date ? value.toISOString() : value;
  });
}
function operation(overrides: Partial<NativeAnnotationOperation> = {}): NativeAnnotationOperation {
  return {
    operationId: 'd65285d5-e052-428f-bb2d-44c1a74432e4',
    clientId,
    bookId: 9,
    baseVersion: 0,
    action: 'create',
    payload: { cfi: 'epubcfi(/6/4)', text: 'passage' },
    ...overrides,
  };
}
function stored(operation: NativeAnnotationOperation, result: object): unknown[] {
  return values(schema.nativeAnnotationOperations, {
    userId: 7,
    operationId: operation.operationId,
    deviceId: 'ipad',
    request: operation,
    result,
    createdAt: now,
  });
}
async function fixture(...results: unknown[][][]) {
  const queue = [...results];
  const query = vi.fn((config: { text: string } | string, params?: unknown[]) => {
    void params;
    const sql = typeof config === 'string' ? config : config.text;
    if (/^(begin|commit|rollback)|pg_advisory_xact_lock/.test(sql)) return Promise.resolve({ rows: [] });
    expect(queue.length, `Unexpected SQL: ${sql}`).toBeGreaterThan(0);
    return Promise.resolve({ rows: queue.shift()! });
  });
  const books = {
    verifyBookAccess: vi.fn().mockResolvedValue({ id: 9 }),
    verifyFileAccess: vi.fn().mockResolvedValue({ id: 10, bookId: 9, format: 'pdf' }),
  };
  const publisher = {
    inspectPage: vi
      .fn()
      .mockResolvedValue({ sourceRevision: 'revision-1', pageFingerprint: 'page-1', page: 2, width: 100, height: 100, canEditPdfInk: true }),
    publish: vi.fn().mockResolvedValue({ published: true, sourceRevision: 'revision-2' }),
  };
  const db = drizzle({ client: { query } as never, schema });
  const module = await Test.createTestingModule({
    providers: [
      NativeAnnotationService,
      { provide: DB, useValue: db },
      { provide: BookService, useValue: books },
      { provide: NATIVE_INK_PUBLISHER, useValue: publisher },
    ],
  }).compile();
  return { service: module.get(NativeAnnotationService), query, books, publisher, assertConsumed: () => expect(queue).toHaveLength(0) };
}
function statements(query: Awaited<ReturnType<typeof fixture>>['query']) {
  return query.mock.calls.map(([config, params]) => ({ sql: typeof config === 'string' ? config : config.text, params }));
}
beforeEach(() => {
  vi.spyOn(Logger.prototype, 'log').mockImplementation(() => undefined);
  vi.spyOn(Logger.prototype, 'warn').mockImplementation(() => undefined);
});
afterEach(() => vi.restoreAllMocks());

describe('NativeAnnotationService reads and checkpoints', () => {
  it('preserves requested order, maps anchors and applies user scope', async () => {
    const f = await fixture(
      [values(schema.annotations, annotation()), values(schema.annotations, annotation({ id: 21, deletedAt: now }))],
      [
        values(schema.annotationPositions, position()),
        values(schema.annotationPositions, position({ annotationId: 21, format: 'pdf', pos0: JSON.stringify(pdf), extras: null })),
      ],
    );
    const items = await f.service.getItems([21, 999, 20], user.id);
    expect(items.map((item) => item.id)).toEqual([21, 20]);
    expect(items[0]).toMatchObject({ pdf, pageno: 3, jumpFileId: 10, deletedAt: now.toISOString() });
    expect(items[1]).toMatchObject({ cfi: 'epubcfi(/6/4)', chapterIndex: 3, highlightedAt: now.toISOString() });
    for (const call of statements(f.query)) {
      expect(call.sql).toContain('"user_id" = $1');
      expect(call.params).toEqual([7, 21, 999, 20]);
    }
    f.assertConsumed();
  });
  it('short-circuits empty IDs and rejects oversized reads and recovery requests', async () => {
    const f = await fixture();
    expect(await f.service.getItems([], user.id)).toEqual([]);
    expect(await f.service.recoverySnapshots(user.id, [])).toEqual(new Map());
    await expect(f.service.getItems(Array(101).fill(1), user.id)).rejects.toBeInstanceOf(BadRequestException);
    await expect(f.service.getSourceItems(9, Array(101).fill(1), user)).rejects.toBeInstanceOf(BadRequestException);
    await expect(f.service.recoverySnapshots(user.id, Array(101).fill(operation()))).rejects.toBeInstanceOf(BadRequestException);
    expect(f.query).not.toHaveBeenCalled();
  });
  it('returns null for an item absent from the reader scope', async () => {
    const f = await fixture([], []);
    expect(await f.service.getItem(999, user.id)).toBeNull();
    f.assertConsumed();
  });
  it('redacts private fields on shared PDF ink and verifies access', async () => {
    const f = await fixture(
      [values(schema.annotations, annotation({ userId: 8, kind: 'pdf_ink', drawing }))],
      [values(schema.annotationPositions, position({ userId: 8, format: 'pdf', pos0: JSON.stringify(pdf) }))],
    );
    const [item] = await f.service.getSourceItems(9, [20], user);
    expect(f.books.verifyBookAccess).toHaveBeenCalledWith(9, user);
    expect(item).toMatchObject({ kind: 'pdf_ink', drawing, text: '', note: null, cfi: null, chapterTitle: null, starredAt: null });
    expect(statements(f.query)[0].params).toEqual([9, 'pdf_ink', 20]);
    f.assertConsumed();
  });
  it('advances a cursor only to delivered rows with bounded lookahead', async () => {
    const f = await fixture(
      [
        [20, 15],
        [21, 16],
      ],
      [values(schema.annotations, annotation())],
      [values(schema.annotationPositions, position())],
    );
    expect(await f.service.delta(user, { bookId: 9, cursor: '14', limit: 1 })).toMatchObject({
      nextCursor: '15',
      hasMore: true,
      items: [{ id: 20 }],
    });
    expect(statements(f.query)[0].params).toEqual([7, 14, 9, 2]);
    expect(statements(f.query)[0].sql).toContain('order by "annotations"."change_sequence" asc');
    f.assertConsumed();
  });
  it('keeps empty delta cursors stable and caps lookahead at 101', async () => {
    const f = await fixture([]);
    expect(await f.service.delta(user, { cursor: '17', limit: 500 })).toEqual({ items: [], nextCursor: '17', hasMore: false });
    expect(statements(f.query)[0].params).toEqual([7, 17, 101]);
    expect(f.books.verifyBookAccess).not.toHaveBeenCalled();
  });
  it('acknowledges per reader, device and book with a monotonic checkpoint', async () => {
    const f = await fixture([]);
    expect(await f.service.acknowledge(user, { deviceId: 'ipad', bookId: 9, cursor: '15' })).toEqual({ acknowledged: true });
    const [call] = statements(f.query);
    expect(call.sql).toContain('on conflict ("user_id","device_id","book_id")');
    expect(call.sql).toContain('greatest("native_annotation_acks"."cursor",');
    expect(call.params?.slice(0, 4)).toEqual([7, 'ipad', 9, 15]);
    f.assertConsumed();
  });
});

describe('NativeAnnotationService persistence and recovery', () => {
  it('creates a personal annotation, upserts its anchor and retains the stable result', async () => {
    const op = operation();
    const f = await fixture(
      [],
      [],
      [],
      [values(schema.annotations, annotation())],
      [],
      [],
      [values(schema.annotations, annotation())],
      [values(schema.annotationPositions, position())],
      [],
    );
    const response = await f.service.operations(user, { deviceId: 'ipad', operations: [op] });
    expect(response.results[0]).toMatchObject({ operationId: op.operationId, status: 'applied', annotation: { id: 20, clientId, version: 1 } });
    const calls = statements(f.query);
    expect(calls.find((call) => call.sql.startsWith('insert into "annotation_positions"'))?.sql).toContain('on conflict ("annotation_id","format")');
    const retained = calls.find((call) => call.sql.startsWith('insert into "native_annotation_operations"'))!;
    expect(retained.params?.slice(0, 3)).toEqual([7, op.operationId, 'ipad']);
    expect(JSON.parse(retained.params?.[4] as string)).toEqual(response.results[0]);
    f.assertConsumed();
  });
  it('replays canonical equivalent JSON without writes and rejects changed operation IDs', async () => {
    const op = operation({ payload: { text: 'passage', cfi: 'epubcfi(/6/4)', drawing } });
    const previous = { ...op, payload: { drawing: { strokes: drawing.strokes, format: drawing.format }, cfi: 'epubcfi(/6/4)', text: 'passage' } };
    const result = { operationId: op.operationId, status: 'applied', annotation: { id: 20 } };
    const f = await fixture([], [stored(previous, result)]);
    expect(await f.service.operations(user, { deviceId: 'ipad', operations: [op] })).toEqual({ results: [result] });
    expect(statements(f.query).some((call) => /^(insert|update)/.test(call.sql))).toBe(false);
    f.assertConsumed();
    const conflict = await fixture([], [stored(previous, result)]);
    await expect(
      conflict.service.operations(user, { deviceId: 'ipad', operations: [{ ...op, payload: { ...op.payload, text: 'changed' } }] }),
    ).rejects.toBeInstanceOf(ConflictException);
    conflict.assertConsumed();
  });
  it('rejects another reader annotation even when the book is accessible', async () => {
    const f = await fixture([], [], [[8]], [], [values(schema.annotations, annotation({ userId: 8 }))]);
    await expect(
      f.service.operations(user, { deviceId: 'ipad', operations: [operation({ annotationId: 20, baseVersion: 1, action: 'update' })] }),
    ).rejects.toBeInstanceOf(ForbiddenException);
    expect(statements(f.query).some((call) => call.sql.startsWith('update'))).toBe(false);
    f.assertConsumed();
  });
  it('retains version conflicts without losing ink or source identity from the base revision', async () => {
    const read = await fixture(
      [values(schema.annotations, annotation({ kind: 'handwriting', drawing, sourceRevision: 'revision-1', pageFingerprint: 'page-1' }))],
      [values(schema.annotationPositions, position({ format: 'pdf', pos0: JSON.stringify(pdf) }))],
    );
    const base = (await read.service.getItems([20], 7))[0];
    const op = operation({ annotationId: 20, action: 'update', baseVersion: 1, payload: { note: 'offline note' } });
    const f = await fixture(
      [values(schema.annotations, annotation({ version: 2 }))],
      [values(schema.annotationPositions, position())],
      [[7]],
      [],
      [values(schema.annotations, annotation({ version: 2 }))],
      [[base]],
      [[44]],
      [values(schema.annotations, annotation({ version: 2 }))],
      [values(schema.annotationPositions, position())],
      [],
    );
    const {
      results: [result],
    } = await f.service.operations(user, { deviceId: 'ipad', operations: [op] });
    expect(result).toMatchObject({
      status: 'conflict',
      draftId: 44,
      annotation: { version: 2 },
      recoverySnapshot: { version: 1, drawing, sourceRevision: 'revision-1', pageFingerprint: 'page-1', note: 'offline note', pdf },
    });
    expect(statements(f.query).find((call) => call.sql.startsWith('insert into "native_annotation_drafts"'))?.params).toContain('version_conflict');
    expect(statements(f.query).some((call) => call.sql.startsWith('update "annotations"'))).toBe(false);
    f.assertConsumed();
  });
  it('reports an unavailable base for missing annotations instead of inventing recovery content', async () => {
    const op = operation({ action: 'delete', annotationId: 20, baseVersion: 1, payload: undefined });
    const f = await fixture([], [], [], [], [], [], [[45]], []);
    expect((await f.service.operations(user, { deviceId: 'ipad', operations: [op] })).results[0]).toEqual({
      operationId: op.operationId,
      status: 'recovery',
      draftId: 45,
      recoverySnapshotUnavailableReason: 'retained_base_unavailable',
    });
    f.assertConsumed();
  });
  it('reconstructs bounded personal and shared snapshots with repaired anchors', async () => {
    const read = await fixture([values(schema.annotations, annotation())], [values(schema.annotationPositions, position())]);
    const base: NativeAnnotationItem = (await read.service.getItems([20], 7))[0];
    const op = operation({ annotationId: 20, action: 'repair', baseVersion: 1, payload: { pdf, bookFileId: 11, note: null, drawing } });
    const f = await fixture([[base]], [[base]]);
    expect((await f.service.recoverySnapshots(7, [op], [op.operationId])).get(op.operationId)).toMatchObject({
      pdf,
      pageno: 3,
      cfi: null,
      jumpFileId: 11,
      drawing,
      note: null,
    });
    const calls = statements(f.query);
    expect(calls[0].params?.[0]).toBe(7);
    expect(calls[1].sql).toContain("->>'kind' = 'pdf_ink'");
    for (const call of calls) expect(call.params?.at(-1)).toBe(100);
    f.assertConsumed();
    const cfi = await fixture([[{ ...base, pdf }]]);
    expect((await cfi.service.recoverySnapshots(7, [{ ...op, payload: { cfi: 'repaired-cfi' } }])).get(op.operationId)).toMatchObject({
      cfi: 'repaired-cfi',
      pdf: null,
      pageno: null,
    });
  });
  it.each([
    { payload: {} },
    { payload: { cfi: 'cfi', pdf, bookFileId: 10 } },
    { payload: { pdf } },
    { payload: { cfi: 'cfi', kind: 'handwriting' as const } },
  ])('rejects invalid create anchors and missing drawing: %j', async ({ payload }) => {
    const f = await fixture([], [], []);
    await expect(f.service.operations(user, { deviceId: 'ipad', operations: [operation({ payload })] })).rejects.toBeInstanceOf(BadRequestException);
    f.assertConsumed();
  });
});

describe('NativeAnnotationService source ink', () => {
  it('requires metadata editing permission and the selected PDF before writes', async () => {
    const f = await fixture();
    await expect(
      f.service.sourceInkOperations({ ...user, permissions: [] }, { bookId: 9, bookFileId: 10 }, { deviceId: 'ipad', operations: [] }),
    ).rejects.toBeInstanceOf(ForbiddenException);
    f.books.verifyFileAccess.mockResolvedValueOnce({ id: 10, bookId: 11, format: 'pdf' });
    await expect(f.service.sourceInkOperations(user, { bookId: 9, bookFileId: 10 }, { deviceId: 'ipad', operations: [] })).rejects.toBeInstanceOf(
      BadRequestException,
    );
    await expect(
      f.service.sourceInkOperations(user, { bookId: 9, bookFileId: 10 }, { deviceId: 'ipad', operations: [operation({ bookId: 12 })] }),
    ).rejects.toBeInstanceOf(BadRequestException);
    expect(f.query).not.toHaveBeenCalled();
  });
  it('applies source ink, publishes its revision and persists the publication result', async () => {
    const op = operation({
      payload: { kind: 'pdf_ink', pdf, bookFileId: 10, drawing, sourceRevision: 'revision-1', pageFingerprint: 'page-1', text: '' },
    });
    const ink = annotation({ kind: 'pdf_ink', drawing, sourceRevision: 'revision-1', pageFingerprint: 'page-1', text: '' });
    const f = await fixture(
      [],
      [],
      [],
      [values(schema.annotations, ink)],
      [],
      [],
      [values(schema.annotations, ink)],
      [values(schema.annotationPositions, position({ format: 'pdf', pos0: JSON.stringify(pdf) }))],
      [],
      [[7]],
      [],
      [],
    );
    const {
      results: [result],
    } = await f.service.sourceInkOperations(user, { bookId: 9, bookFileId: 10 }, { deviceId: 'ipad', operations: [op] });
    expect(result).toMatchObject({
      status: 'applied',
      annotation: { sourceRevision: 'revision-2', text: '', note: null },
      publication: { status: 'published', sourceRevision: 'revision-2' },
    });
    expect(f.publisher.inspectPage).toHaveBeenCalledWith(9, 10, 2, user, 'revision-1');
    expect(f.publisher.publish).toHaveBeenCalledWith(
      expect.objectContaining({ annotationId: 20, version: 1, drawing, operationId: op.operationId, deleted: false }),
    );
    expect(statements(f.query).some((call) => call.sql.startsWith('update "native_annotation_operations"'))).toBe(true);
    f.assertConsumed();
  });
  it('retains missing source revisions as recovery without publishing or losing drawing', async () => {
    const op = operation({ payload: { kind: 'pdf_ink', pdf, bookFileId: 10, drawing, pageFingerprint: 'page-1' } });
    const f = await fixture([], [], [], [[51]], []);
    expect((await f.service.operations(user, { deviceId: 'ipad', operations: [op] })).results[0]).toMatchObject({ status: 'recovery', draftId: 51 });
    const draft = statements(f.query).find((call) => call.sql.startsWith('insert into "native_annotation_drafts"'))!;
    expect(draft.params).toContain('source_revision_missing');
    expect(JSON.parse(draft.params?.[5] as string).payload.drawing).toEqual(drawing);
    expect(f.publisher.publish).not.toHaveBeenCalled();
    f.assertConsumed();
  });
  it('rejects excessive point counts and mismatched files before persistence', async () => {
    const f = await fixture();
    await expect(
      f.service.operations(user, {
        deviceId: 'ipad',
        operations: [
          operation({ payload: { drawing: { ...drawing, strokes: [{ ...drawing.strokes[0], points: Array(50001).fill({ x: 1, y: 2 }) }] } } }),
        ],
      }),
    ).rejects.toBeInstanceOf(BadRequestException);
    f.books.verifyFileAccess.mockResolvedValueOnce({ id: 10, bookId: 12, format: 'pdf' });
    await expect(
      f.service.operations(user, { deviceId: 'ipad', operations: [operation({ payload: { pdf, bookFileId: 10 } })] }),
    ).rejects.toBeInstanceOf(BadRequestException);
    expect(f.query).not.toHaveBeenCalled();
  });
  it('converts missing files into retained recovery drafts', async () => {
    const f = await fixture([], [], [], [[52]], []);
    f.books.verifyFileAccess.mockRejectedValueOnce(new NotFoundException('gone'));
    const op = operation({ payload: { kind: 'pdf_ink', pdf, bookFileId: 10, drawing } });
    expect((await f.service.operations(user, { deviceId: 'ipad', operations: [op] })).results[0]).toMatchObject({ status: 'recovery', draftId: 52 });
    expect(statements(f.query).find((call) => call.sql.startsWith('insert into "native_annotation_drafts"'))?.params).toContain('source_missing');
    f.assertConsumed();
  });
});
