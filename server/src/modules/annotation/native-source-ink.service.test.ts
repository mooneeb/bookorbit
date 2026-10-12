import { BadRequestException, ForbiddenException } from '@nestjs/common';
import { Test } from '@nestjs/testing';
import { Permission, type NativeAnnotationItem, type NativeAnnotationOperationsRequest } from '@bookorbit/types';
import { drizzle } from 'drizzle-orm/node-postgres';
import type { RequestUser } from '../../common/types/request-user';
import { DB } from '../../db';
import * as schema from '../../db/schema';
import { BookService } from '../book/book.service';
import { NativeAnnotationService } from './native-annotation.service';
import { NativeSourceInkService } from './native-source-ink.service';

const user: RequestUser = {
  id: 41,
  username: 'reader',
  name: 'Reader',
  email: null,
  active: true,
  isSuperuser: false,
  isDefaultPassword: false,
  tokenVersion: 0,
  settings: {},
  avatarUrl: null,
  provisioningMethod: 'local',
  permissions: [Permission.LibraryEditMetadata],
  contentFilters: {},
};
const scope = { bookId: 5, bookFileId: 12 };
const pdf = { page: 3, rect: { x: 1, y: 2, width: 3, height: 4 }, rects: [] };
const timestamp = '2026-10-01T00:00:00.000Z';

function windowRow(id: number, position: string | null = JSON.stringify(pdf), sourceCreatedAt: string | null = null) {
  return [
    id,
    5,
    `client-${id}`,
    'pdf_ink',
    2,
    'revision-1',
    'fingerprint-3',
    '#123456',
    'highlight',
    'native',
    timestamp,
    timestamp,
    sourceCreatedAt,
    position,
    'exact',
    '23',
  ];
}

async function fixture(...results: unknown[][][]) {
  const query = vi.fn<(config: { text: string }, params: unknown[]) => Promise<{ rows: unknown[][] }>>();
  for (const rows of results) query.mockResolvedValueOnce({ rows });
  query.mockResolvedValue({ rows: [] });
  const books = {
    verifyBookAccess: vi.fn().mockImplementation((_bookId: number, requester: RequestUser) => {
      if (requester.id !== user.id) throw new ForbiddenException('Book is inaccessible');
      return Promise.resolve({ id: 5 });
    }),
    verifyFileAccess: vi.fn().mockResolvedValue({ id: 12, bookId: 5, format: 'pdf' }),
  };
  const module = await Test.createTestingModule({
    providers: [
      NativeSourceInkService,
      NativeAnnotationService,
      { provide: DB, useValue: drizzle({ client: { query } as never, schema }) },
      { provide: BookService, useValue: books },
    ],
  }).compile();
  const annotations = module.get(NativeAnnotationService);
  return { service: module.get(NativeSourceInkService), annotations, books, query };
}

describe('NativeSourceInkService', () => {
  it('returns a bounded PDF page window with stable IDs, geometry and source identity', async () => {
    const { service, books, query } = await fixture([windowRow(7, JSON.stringify(pdf), '2026-09-20T00:00:00.000Z')]);

    const result = await service.window(user, { ...scope, page: 3, window: 2, limit: 10 });

    expect(result).toMatchObject({ total: 23, window: 2, limit: 10 });
    expect(result.items).toEqual([
      expect.objectContaining({
        id: 7,
        bookId: 5,
        kind: 'pdf_ink',
        version: 2,
        pdf,
        pageno: 4,
        jumpFileId: 12,
        sourceRevision: 'revision-1',
        pageFingerprint: 'fingerprint-3',
        highlightedAt: '2026-09-20T00:00:00.000Z',
        createdAt: timestamp,
        updatedAt: timestamp,
        drawing: null,
        text: '',
        note: null,
      }),
    ]);
    expect(books.verifyBookAccess).toHaveBeenCalledWith(5, user);
    expect(books.verifyFileAccess).toHaveBeenCalledWith(12, user);
    expect(query).toHaveBeenCalledTimes(1);
    const [statement, params] = query.mock.calls[0];
    expect(params).toEqual([5, 'pdf_ink', 12, 'pdf', '4', 10, 10]);
    expect(statement.text).toContain('"annotations"."deleted_at" is null');
    expect(statement.text).toContain('"annotation_positions"."extras"->>\'pageno\'');
    expect(statement.text).toContain('order by "annotations"."id" asc limit $6 offset $7');
    expect(statement.text).not.toContain('"drawing"');
  });

  it('uses bounded defaults and tolerates missing or malformed stored PDF geometry', async () => {
    const { service, query } = await fixture([windowRow(7, '{invalid'), windowRow(8, null)]);
    const result = await service.window(user, { ...scope, page: 0 });
    expect(result).toMatchObject({ total: 23, window: 1, limit: 100 });
    expect(result.items.map((item) => item.pdf)).toEqual([null, null]);
    expect(result.items.map((item) => item.highlightedAt)).toEqual([timestamp, timestamp]);
    expect(query.mock.calls[0][1]).toEqual([5, 'pdf_ink', 12, 'pdf', '1', 100]);
  });

  it('counts matching ink for an empty later window using the same file and page predicates', async () => {
    const { service, query } = await fixture([], [['23']]);
    await expect(service.window(user, { ...scope, page: 3, window: 4, limit: 10 })).resolves.toEqual({ items: [], total: 23, window: 4, limit: 10 });
    expect(query.mock.calls[0][1]).toEqual([5, 'pdf_ink', 12, 'pdf', '4', 10, 30]);
    expect(query.mock.calls[1][1]).toEqual([5, 'pdf_ink', 12, 'pdf', '4']);
    expect(query.mock.calls[1][0].text).toContain('count(*)');
  });

  it('returns an empty first window without an extra count query', async () => {
    const { service, query } = await fixture();
    await expect(service.window(user, { ...scope, page: 0 })).resolves.toEqual({ items: [], total: 0, window: 1, limit: 100 });
    expect(query).toHaveBeenCalledTimes(1);
  });

  it('preserves a total of zero when a later window count has no row', async () => {
    const { service } = await fixture([], []);
    await expect(service.window(user, { ...scope, page: 0, window: 2 })).resolves.toMatchObject({ items: [], total: 0 });
  });

  it.each(['window', 'delta'] as const)('denies %s before querying ink for an inaccessible user', async (method) => {
    const { service, query, books } = await fixture([windowRow(7)]);
    await expect(service[method]({ ...user, id: 42 }, { ...scope, page: 3 })).rejects.toBeInstanceOf(ForbiddenException);
    expect(query).not.toHaveBeenCalled();
    expect(books.verifyFileAccess).not.toHaveBeenCalled();
  });

  it.each([
    ['window', { bookId: 6, format: 'pdf' }],
    ['window', { bookId: 5, format: 'epub' }],
    ['delta', { bookId: 6, format: 'pdf' }],
    ['delta', { bookId: 5, format: 'epub' }],
  ] as const)('rejects %s when the selected file is incompatible: %o', async (method, file) => {
    const { service, query, books } = await fixture();
    books.verifyFileAccess.mockResolvedValueOnce(file);
    await expect(service[method](user, { ...scope, page: 3 })).rejects.toBeInstanceOf(BadRequestException);
    expect(query).not.toHaveBeenCalled();
  });

  it('advances the delta cursor over the bounded sequence page and excludes mismatched source anchors', async () => {
    const { service, annotations, query } = await fixture([
      [7, '11'],
      [8, '13'],
      [9, '14'],
    ]);
    const items = [
      { id: 7, jumpFileId: 12, pdf },
      { id: 8, jumpFileId: 99, pdf },
      { id: 9, jumpFileId: 12, pdf: { ...pdf, page: 4 } },
      { id: 10, jumpFileId: 12, pdf: null },
    ] as NativeAnnotationItem[];
    const read = vi.spyOn(annotations, 'getSourceItems').mockResolvedValue(items);
    await expect(service.delta(user, { ...scope, page: 3, cursor: '10', limit: 2 })).resolves.toEqual({
      items: [items[0]],
      nextCursor: '13',
      hasMore: true,
    });
    expect(read).toHaveBeenCalledWith(5, [7, 8], user);
    expect(query.mock.calls[0][1]).toEqual([5, 'pdf_ink', 10, 12, 'pdf', '4', 3]);
    expect(query.mock.calls[0][0].text).toContain('order by "annotations"."change_sequence" asc');
    expect(query.mock.calls[0][0].text).not.toContain('"deleted_at" is null');
  });

  it('reads delta across all pages with a 100 item cap and includes deletion anchors', async () => {
    const { service, annotations, query } = await fixture([[7, '8']]);
    const item = { id: 7, jumpFileId: 12, pdf: null, deletedAt: timestamp } as NativeAnnotationItem;
    vi.spyOn(annotations, 'getSourceItems').mockResolvedValue([item]);
    await expect(service.delta(user, { ...scope, limit: 500 })).resolves.toEqual({ items: [item], nextCursor: '8', hasMore: false });
    expect(query.mock.calls[0][1]).toEqual([5, 'pdf_ink', 0, 12, 'pdf', 101]);
    expect(query.mock.calls[0][0].text).not.toContain('pageno');
  });

  it('keeps the requested cursor when no delta rows remain', async () => {
    const { service, annotations, query } = await fixture();
    vi.spyOn(annotations, 'getSourceItems').mockResolvedValue([]);
    await expect(service.delta(user, { ...scope, cursor: '18' })).resolves.toEqual({ items: [], nextCursor: '18', hasMore: false });
    expect(query.mock.calls[0][1]).toEqual([5, 'pdf_ink', 18, 12, 'pdf', 101]);
  });

  it('forwards native ink and revision references to the scoped operation boundary without changing the result', async () => {
    const { service, annotations } = await fixture();
    const dto: NativeAnnotationOperationsRequest = {
      deviceId: 'ipad',
      operations: [
        {
          operationId: 'e3bd84ba-1995-4ccb-bf59-79c16c93ee52',
          clientId: 'b9061969-d213-4b90-a7e6-bf71f7b7fc43',
          bookId: 5,
          action: 'create',
          baseVersion: 0,
          payload: {
            kind: 'pdf_ink',
            bookFileId: 12,
            pdf,
            sourceRevision: 'revision-1',
            pageFingerprint: 'fingerprint-3',
            drawing: { format: 'bookorbit-ink-v1', strokes: [], nativeData: 'native-pencilkit-data' },
          },
        },
      ],
    };
    const response = { results: [], cursor: '18' };
    const apply = vi.spyOn(annotations, 'operations').mockResolvedValue(response);
    await expect(service.operations(user, scope, dto)).resolves.toBe(response);
    expect(apply).toHaveBeenCalledWith(user, dto, scope);
  });

  it('enforces source operation ownership, editing permission and scope before any mutation', async () => {
    const { service, annotations, query } = await fixture();
    const apply = vi.spyOn(annotations, 'operations');
    await expect(service.operations({ ...user, id: 42 }, scope, { deviceId: 'ipad', operations: [] })).rejects.toBeInstanceOf(ForbiddenException);
    await expect(service.operations({ ...user, permissions: [] }, scope, { deviceId: 'ipad', operations: [] })).rejects.toBeInstanceOf(
      ForbiddenException,
    );
    for (const operation of [{ bookId: 6 }, { bookId: 5, payload: { bookFileId: 99 } }]) {
      await expect(
        service.operations(user, scope, { deviceId: 'ipad', operations: [operation as NativeAnnotationOperationsRequest['operations'][number]] }),
      ).rejects.toBeInstanceOf(BadRequestException);
    }
    expect(apply).not.toHaveBeenCalled();
    expect(query).not.toHaveBeenCalled();
  });
});
