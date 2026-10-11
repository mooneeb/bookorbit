import { Permission } from '@bookorbit/types';
import { UnauthorizedException, ValidationPipe, type ExecutionContext } from '@nestjs/common';
import { Reflector } from '@nestjs/core';
import { FastifyAdapter, type NestFastifyApplication } from '@nestjs/platform-fastify';
import { Test } from '@nestjs/testing';
import { PermissionGuard } from '../../common/guards/permission.guard';
import { PermissionService } from '../../common/services/permission.service';
import type { RequestUser } from '../../common/types/request-user';
import { NativeAnnotationHubController } from './native-annotation-hub.controller';
import { NativeAnnotationHubService } from './native-annotation-hub.service';
const reader = { id: 7, isSuperuser: false, permissions: [] } as unknown as RequestUser;
const owner = { ...reader, permissions: [Permission.AnnotationManageOwn] };
const actors: Record<string, RequestUser> = { reader, owner };
const service = { list: vi.fn(), export: vi.fn(), drafts: vi.fn(), devices: vi.fn(), bulk: vi.fn(), repair: vi.fn() };
const operation = {
  operationId: 'd7e2d3d0-a60d-4f0f-9271-5c35dfd7e7c5',
  clientId: 'a07d242a-5a53-4cb1-a79d-0d7394459af1',
  annotationId: 9,
  bookId: 4,
  baseVersion: 3,
  action: 'delete',
};
const bulk = { deviceId: 'tablet', operations: [operation] };
describe('NativeAnnotationHubController authenticated HTTP contract', () => {
  let app: NestFastifyApplication;
  beforeAll(async () => {
    const module = await Test.createTestingModule({
      controllers: [NativeAnnotationHubController],
      providers: [{ provide: NativeAnnotationHubService, useValue: service }],
    }).compile();
    app = module.createNestApplication<NestFastifyApplication>(new FastifyAdapter());
    app.setGlobalPrefix('api/v1');
    app.useGlobalPipes(new ValidationPipe({ whitelist: true, forbidNonWhitelisted: true, transform: true }));
    app.useGlobalGuards(
      {
        canActivate(context: ExecutionContext) {
          const request = context.switchToHttp().getRequest<{ headers: { authorization?: string }; user?: RequestUser }>();
          const actor = actors[request.headers.authorization ?? ''];
          if (!actor) throw new UnauthorizedException();
          request.user = actor;
          return true;
        },
      },
      new PermissionGuard(module.get(Reflector), new PermissionService()),
    );
    await app.init();
    await app.getHttpAdapter().getInstance().ready();
  });
  beforeEach(() => vi.resetAllMocks());
  afterAll(async () => app?.close());
  function request(method: 'GET' | 'POST', path: string, actor = 'owner', payload?: object) {
    return app.inject({ method, url: `/api/v1/annotations/native/hub${path}`, headers: { authorization: actor }, payload });
  }
  it('lists only the authenticated account and transforms bounded filters', async () => {
    service.list.mockResolvedValue({ items: [{ id: 9 }], nextCursor: 9 });
    const response = await request(
      'GET',
      '?cursor=10&limit=1&bookId=4&fileId=5&search=%20ink%20&kind=pdf_ink&status=recovery&groupBy=month',
      'reader',
    );
    expect(response.statusCode).toBe(200);
    expect(response.json()).toEqual({ items: [{ id: 9 }], nextCursor: 9 });
    expect(service.list).toHaveBeenCalledExactlyOnceWith(7, {
      cursor: 10,
      limit: 1,
      bookId: 4,
      fileId: 5,
      search: 'ink',
      kind: 'pdf_ink',
      status: 'recovery',
      groupBy: 'month',
    });
  });
  it('exports authenticated selections with exact download headers and content', async () => {
    service.export.mockResolvedValue({
      contentType: 'application/json; charset=utf-8',
      filename: 'bookorbit-annotations.json',
      content: '{"format":"bookorbit-annotations-v1"}',
    });
    const response = await request('GET', '/export?ids=9,10&limit=2');
    expect(response.statusCode).toBe(200);
    expect(response.headers['content-type']).toContain('application/json');
    expect(response.headers['content-disposition']).toBe('attachment; filename="bookorbit-annotations.json"');
    expect(response.body).toBe('{"format":"bookorbit-annotations-v1"}');
    expect(service.export).toHaveBeenCalledExactlyOnceWith(7, { ids: [9, 10], limit: 2 });
  });
  it('preserves distinct draft and device response shapes', async () => {
    const drafts = { items: [{ id: 3, snapshotUnavailableReason: 'retained_base_unavailable' }], nextCursor: 3 };
    service.drafts.mockResolvedValue(drafts);
    expect((await request('GET', '/drafts?cursor=4&limit=1&bookId=4')).json()).toEqual(drafts);
    expect(service.drafts).toHaveBeenCalledExactlyOnceWith(7, { cursor: 4, limit: 1, bookId: 4 });
    const devices = { items: [{ deviceId: 'tablet', bookId: 4, cursor: '12' }], nextCursor: 'opaque' };
    service.devices.mockResolvedValue(devices);
    expect((await request('GET', '/devices?cursor=opaque&limit=1&bookId=4')).json()).toEqual(devices);
    expect(service.devices).toHaveBeenCalledExactlyOnceWith(7, { cursor: 'opaque', limit: 1, bookId: 4 });
  });
  it('passes the full actor and base revision and returns conflicts with HTTP 200', async () => {
    const result = { results: [{ operationId: operation.operationId, status: 'conflict', annotation: { id: 9, version: 4 } }] };
    service.bulk.mockResolvedValue(result);
    const response = await request('POST', '/bulk', 'owner', bulk);
    expect(response.statusCode).toBe(200);
    expect(response.json()).toEqual(result);
    expect(service.bulk).toHaveBeenCalledExactlyOnceWith(owner, bulk);
  });
  it('forwards validated nested repair ink and retained source data', async () => {
    const payload = {
      deviceId: 'tablet',
      operations: [
        {
          ...operation,
          action: 'repair',
          payload: {
            kind: 'pdf_ink',
            bookFileId: 5,
            sourceRevision: 'r2',
            pageFingerprint: 'page1',
            drawing: {
              format: 'bookorbit-ink-v1',
              strokes: [{ id: 'stroke', color: '#112233', width: 2, points: [{ x: 1, y: 2, pressure: 0.5 }] }],
              nativeData: 'original-source',
            },
          },
        },
      ],
    };
    service.repair.mockResolvedValue({ results: [{ operationId: operation.operationId, status: 'recovery', draftId: 3 }] });
    const response = await request('POST', '/9/repair', 'owner', payload);
    expect(response.statusCode).toBe(200);
    expect(response.json().results[0].draftId).toBe(3);
    expect(service.repair).toHaveBeenCalledExactlyOnceWith(owner, 9, payload);
  });
  it.each([
    ['GET', '/export', undefined],
    ['GET', '/drafts', undefined],
    ['GET', '/devices', undefined],
    ['POST', '/bulk', bulk],
    ['POST', '/9/repair', bulk],
  ] as const)('requires manage permission for %s %s', async (method, path, payload) => {
    expect((await request(method, path, 'reader', payload)).statusCode).toBe(403);
    for (const action of Object.values(service)) expect(action).not.toHaveBeenCalled();
  });
  it.each([
    ['GET', '', undefined],
    ['POST', '/bulk', bulk],
  ] as const)('requires authentication for %s %s', async (method, path, payload) => {
    expect((await request(method, path, 'unknown', payload)).statusCode).toBe(401);
    for (const action of Object.values(service)) expect(action).not.toHaveBeenCalled();
  });
  it.each([
    ['GET', '?userId=8', undefined],
    ['GET', '?limit=101', undefined],
    ['GET', '/devices?limit=0', undefined],
    ['GET', '/export?ids=9,abc', undefined],
    ['POST', '/not-a-number/repair', bulk],
    ['POST', '/bulk', { ...bulk, userId: 8 }],
    ['POST', '/bulk', { ...bulk, operations: [{ ...operation, baseVersion: -1 }] }],
    [
      'POST',
      '/9/repair',
      {
        ...bulk,
        operations: [
          {
            ...operation,
            action: 'repair',
            payload: {
              drawing: { format: 'bookorbit-ink-v1', strokes: [{ id: 'a', color: '#112233', width: 2, points: [{ x: 1, y: 2, pressure: 2 }] }] },
            },
          },
        ],
      },
    ],
    [
      'POST',
      '/9/repair',
      { ...bulk, operations: [{ ...operation, action: 'repair', payload: { drawing: { format: 'bookorbit-ink-v1', strokes: [], admin: true } } }] },
    ],
  ] as const)('rejects invalid %s %s before hub invocation', async (method, path, payload) => {
    expect((await request(method, path, 'owner', payload)).statusCode).toBe(400);
    for (const action of Object.values(service)) expect(action).not.toHaveBeenCalled();
  });
});
