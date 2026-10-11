import { BadRequestException, ForbiddenException, UnauthorizedException, ValidationPipe } from '@nestjs/common';
import { Reflector } from '@nestjs/core';
import { FastifyAdapter, type NestFastifyApplication } from '@nestjs/platform-fastify';
import { Test } from '@nestjs/testing';
import { PgDialect } from 'drizzle-orm/pg-core';
import type { Mock } from 'vitest';

import { AuditAction, AuditResource, Permission } from '@bookorbit/types';
import { LibraryAccessGuard } from '../../common/guards/library-access.guard';
import { PermissionGuard } from '../../common/guards/permission.guard';
import { AuditInterceptor } from '../../common/interceptors/audit.interceptor';
import { PermissionService } from '../../common/services/permission.service';
import type { RequestUser } from '../../common/types/request-user';
import { AUDIT_EVENT, type AuditEventPayload } from '../audit/audit-events.service';
import { BookService } from '../book/book.service';
import { BulkRenameService } from './bulk-rename.service';
import { LibraryAddedAtService } from './library-added-at.service';
import { LibraryController } from './library.controller';
import { LibraryService } from './library.service';

describe('LibraryController', () => {
  const libraryService = {
    findAll: vi.fn(),
    findOne: vi.fn(),
    create: vi.fn(),
    update: vi.fn(),
    remove: vi.fn(),
    prescan: vi.fn(),
    reorder: vi.fn(),
    getStats: vi.fn(),
    getOverview: vi.fn(),
    getAccess: vi.fn(),
    grantAccess: vi.fn(),
    updateAccess: vi.fn(),
    revokeAccess: vi.fn(),
    writeMetadataToFiles: vi.fn(),
  };

  const bookService = { queryForLibrary: vi.fn(), queryJumpBucketsForLibrary: vi.fn() };

  const bulkRenameService = {
    getPreview: vi.fn(),
    isRunning: vi.fn(),
    execute: vi.fn(),
  };

  const addedAtService = { start: vi.fn(), get: vi.fn() };
  const controller = new LibraryController(libraryService as any, bookService as any, bulkRenameService as any, addedAtService as any);

  beforeEach(() => {
    vi.resetAllMocks();
  });

  it('getOverview passes the caller through so the service can scope the result', async () => {
    const user = { id: 7, isSuperuser: false } as any;
    libraryService.getOverview.mockResolvedValue([]);

    await controller.getOverview(user);

    expect(libraryService.getOverview).toHaveBeenCalledWith(user);
  });

  it('writeMetadataToFiles blocks non-dry-run when file write is disabled', async () => {
    libraryService.writeMetadataToFiles.mockRejectedValue(new BadRequestException('disabled'));
    const reply = {
      raw: {
        writeHead: vi.fn(),
        on: vi.fn(),
        off: vi.fn(),
        writableEnded: false,
        destroyed: false,
      },
    };

    await expect(controller.writeMetadataToFiles(1, undefined, { id: 1, isSuperuser: true } as any, reply as any)).rejects.toBeInstanceOf(
      BadRequestException,
    );
  });

  it('writeMetadataToFiles streams progress and final done event with counters', async () => {
    libraryService.writeMetadataToFiles.mockImplementation(
      (_libraryId: number, _userId: number, _dryRun: boolean, options: { onProgress?: (event: unknown) => void }) => {
        options.onProgress?.({ bookId: 1, status: 'success' });
        options.onProgress?.({ bookId: 2, status: 'failed', reason: 'write failed' });
        options.onProgress?.({ bookId: 3, status: 'skipped', reason: 'no changes' });
        return Promise.resolve({ processed: 3, succeeded: 1, failed: 1, skipped: 1 });
      },
    );

    const reply = {
      raw: {
        writeHead: vi.fn(),
        write: vi.fn(),
        end: vi.fn(),
        on: vi.fn(),
        off: vi.fn(),
        writableEnded: false,
        destroyed: false,
      },
    };

    await controller.writeMetadataToFiles(1, 'false', { id: 7, isSuperuser: false } as any, reply as any);

    expect(reply.raw.writeHead).toHaveBeenCalledWith(200, expect.objectContaining({ 'Content-Type': 'text/event-stream' }));
    expect(reply.raw.write).toHaveBeenCalledTimes(4);
    expect(reply.raw.off).toHaveBeenCalledWith('close', expect.any(Function));
    expect(reply.raw.off).toHaveBeenCalledWith('aborted', expect.any(Function));

    const doneLine = (reply.raw.write as Mock).mock.calls[3][0] as string;
    const donePayload = JSON.parse(doneLine.replace(/^data:\s*/, '').trim());
    expect(donePayload).toEqual(expect.objectContaining({ done: true, processed: 3, succeeded: 1, failed: 1, skipped: 1 }));
    expect(reply.raw.end).toHaveBeenCalled();
  });

  it('writeMetadataToFiles does not emit done event when disconnected mid-stream', async () => {
    let disconnect: (() => void) | undefined;
    libraryService.writeMetadataToFiles.mockImplementation(
      (_libraryId: number, _userId: number, _dryRun: boolean, options: { onProgress?: (event: unknown) => void }) => {
        options.onProgress?.({ bookId: 1, status: 'success' });
        disconnect?.();
        options.onProgress?.({ bookId: 2, status: 'success' });
        return Promise.resolve({ processed: 2, succeeded: 2, failed: 0, skipped: 0 });
      },
    );
    const reply = {
      raw: {
        writeHead: vi.fn(),
        write: vi.fn(),
        end: vi.fn(),
        on: vi.fn((event: string, handler: () => void) => {
          if (event === 'close') disconnect = handler;
        }),
        off: vi.fn(),
        writableEnded: false,
        destroyed: false,
      },
    };

    await controller.writeMetadataToFiles(1, 'true', { id: 1, isSuperuser: true } as any, reply as any);

    expect(reply.raw.write).toHaveBeenCalledTimes(1);
    expect(reply.raw.end).toHaveBeenCalled();
  });

  it('queryBooks and queryJumpBuckets delegate to the book service', async () => {
    const user = { id: 4, isSuperuser: false } as any;
    const query = { sort: [{ field: 'title', dir: 'asc' }], pagination: { page: 0, size: 50 } } as any;

    await controller.queryBooks(7, query, user);
    await controller.queryJumpBuckets(7, query, user);

    expect(bookService.queryForLibrary).toHaveBeenCalledWith(user, 7, query);
    expect(bookService.queryJumpBucketsForLibrary).toHaveBeenCalledWith(user, 7, query);
  });

  it('bulk rename stops emitting progress after a disconnect and exposes cancellation to the worker', async () => {
    let disconnect: (() => void) | undefined;
    bulkRenameService.execute.mockImplementation((_libraryId, _userId, options) => {
      expect(options.isCancelled()).toBe(false);
      options.onProgress({ bookId: 101, status: 'success' });
      disconnect?.();
      expect(options.isCancelled()).toBe(true);
      options.onProgress({ bookId: 102, status: 'success' });
      return Promise.resolve({ processed: 2, succeeded: 2, failed: 0, skipped: 0 });
    });
    const reply = {
      raw: {
        writeHead: vi.fn(),
        write: vi.fn(),
        end: vi.fn(),
        on: vi.fn((event: string, handler: () => void) => {
          if (event === 'aborted') disconnect = handler;
        }),
        off: vi.fn(),
        writableEnded: false,
        destroyed: false,
      },
    };

    await controller.executeBulkRename(
      31,
      { previewToken: 'a924c342-cb64-4cb7-952b-e6b937b5e405', excludeBookIds: [103] },
      { id: 7, isSuperuser: false } as any,
      reply as any,
    );

    expect(reply.raw.write).toHaveBeenCalledExactlyOnceWith('data: {"bookId":101,"status":"success"}\n\n');
    expect(reply.raw.end).toHaveBeenCalledOnce();
    expect(reply.raw.off).toHaveBeenCalledWith('close', expect.any(Function));
    expect(reply.raw.off).toHaveBeenCalledWith('aborted', expect.any(Function));
    expect(bulkRenameService.execute).toHaveBeenCalledWith(31, 7, expect.objectContaining({ excludeBookIds: [103], includeBookIds: undefined }));
  });
});

describe('LibraryController HTTP contracts and audit events', () => {
  let app: NestFastifyApplication;
  let user: RequestUser | undefined;
  const actor = {
    id: 7,
    username: 'library-admin',
    isSuperuser: false,
    permissions: [Permission.ManageLibraries, Permission.LibraryEditMetadata],
  } as RequestUser;
  const library = { id: 31, name: 'Reading', type: 'books' };
  const libraryService = {
    findAll: vi.fn(),
    findOne: vi.fn(),
    create: vi.fn(),
    update: vi.fn(),
    remove: vi.fn(),
    prescan: vi.fn(),
    reorder: vi.fn(),
    getStats: vi.fn(),
    getOverview: vi.fn(),
    getAccess: vi.fn(),
    grantAccess: vi.fn(),
    updateAccess: vi.fn(),
    revokeAccess: vi.fn(),
    findMoveDestinations: vi.fn(),
    findMoveFolders: vi.fn(),
    writeMetadataToFiles: vi.fn(),
  };
  const bookService = { queryForLibrary: vi.fn(), queryJumpBucketsForLibrary: vi.fn() };
  const bulkRenameService = { getPreview: vi.fn(), isRunning: vi.fn(), execute: vi.fn() };
  const addedAtService = { start: vi.fn(), get: vi.fn() };
  const db = { query: { libraries: { findFirst: vi.fn() }, userLibraryAccess: { findFirst: vi.fn() } } };
  const auditEvents = { emit: vi.fn() };
  const previewToken = 'a924c342-cb64-4cb7-952b-e6b937b5e405';
  const summary = { processed: 1, succeeded: 1, failed: 0, skipped: 0 };

  beforeAll(async () => {
    const module = await Test.createTestingModule({
      controllers: [LibraryController],
      providers: [
        { provide: LibraryService, useValue: libraryService },
        { provide: BookService, useValue: bookService },
        { provide: BulkRenameService, useValue: bulkRenameService },
        { provide: LibraryAddedAtService, useValue: addedAtService },
      ],
    }).compile();
    app = module.createNestApplication<NestFastifyApplication>(new FastifyAdapter());
    app.setGlobalPrefix('api/v1');
    const reflector = new Reflector();
    app.useGlobalGuards(
      {
        canActivate(context) {
          if (!user) throw new UnauthorizedException();
          context.switchToHttp().getRequest<{ user: RequestUser }>().user = user;
          return true;
        },
      },
      new PermissionGuard(reflector, new PermissionService()),
      new LibraryAccessGuard(reflector, db as never),
    );
    app.useGlobalPipes(new ValidationPipe({ whitelist: true, forbidNonWhitelisted: true, transform: true }));
    app.useGlobalInterceptors(new AuditInterceptor(reflector, auditEvents as never));
    await app.init();
    await app.getHttpAdapter().getInstance().ready();
  });
  afterAll(async () => {
    await app?.close();
  });
  beforeEach(() => {
    vi.resetAllMocks();
    user = actor;
    db.query.libraries.findFirst.mockResolvedValue({ type: 'books' });
    db.query.userLibraryAccess.findFirst.mockResolvedValue({ accessLevel: 'owner' });
  });
  function expectAudit(action: AuditAction, description: string) {
    expect(auditEvents.emit).toHaveBeenCalledExactlyOnceWith(AUDIT_EVENT, {
      userId: actor.id,
      actorUsername: actor.username,
      action,
      resource: AuditResource.Library,
      resourceId: library.id,
      description,
      ip: '127.0.0.1',
    } satisfies AuditEventPayload);
  }

  it('requires authentication before reading a library', async () => {
    user = undefined;
    const response = await app.inject({ method: 'GET', url: '/api/v1/libraries/31' });
    expect(response.statusCode).toBe(401);
    expect(libraryService.findOne).not.toHaveBeenCalled();
    expect(auditEvents.emit).not.toHaveBeenCalled();
  });
  it('scopes listing and the static overview route to the caller', async () => {
    libraryService.findAll.mockResolvedValue([library]);
    libraryService.getOverview.mockResolvedValue([{ ...library, bookCount: 90000 }]);
    const list = await app.inject({ method: 'GET', url: '/api/v1/libraries' });
    const overview = await app.inject({ method: 'GET', url: '/api/v1/libraries/overview' });
    expect(list.json()).toEqual([library]);
    expect(overview.statusCode).toBe(200);
    expect(overview.json()).toEqual([{ ...library, bookCount: 90000 }]);
    expect(libraryService.findAll).toHaveBeenCalledWith(actor);
    expect(libraryService.getOverview).toHaveBeenCalledWith(actor);
    expect(libraryService.findOne).not.toHaveBeenCalled();
  });
  it('checks the caller and library IDs before serving a library', async () => {
    libraryService.findOne.mockResolvedValue(library);
    const response = await app.inject({ method: 'GET', url: '/api/v1/libraries/31' });
    expect(response.json()).toEqual(library);
    expect(libraryService.findOne).toHaveBeenCalledWith(31);
    const condition = db.query.userLibraryAccess.findFirst.mock.calls[0][0].where;
    expect(new PgDialect().sqlToQuery(condition).params).toEqual([actor.id, 31]);
  });
  it.each([
    ['GET', '/api/v1/libraries/overview'],
    ['POST', '/api/v1/libraries'],
    ['DELETE', '/api/v1/libraries/31'],
    ['POST', '/api/v1/libraries/31/access'],
  ] as const)('rejects %s %s without ManageLibraries', async (method, url) => {
    user = { ...actor, permissions: [] };
    const response = await app.inject({ method, url });
    expect(response.statusCode).toBe(403);
    expect(db.query.userLibraryAccess.findFirst).not.toHaveBeenCalled();
    expect(auditEvents.emit).not.toHaveBeenCalled();
    expect(libraryService.remove).not.toHaveBeenCalled();
    expect(libraryService.grantAccess).not.toHaveBeenCalled();
  });
  it.each([
    ['GET', '/api/v1/libraries/31', undefined],
    ['PATCH', '/api/v1/libraries/31', { accessLevel: 'viewer' }],
    ['DELETE', '/api/v1/libraries/31', { accessLevel: 'editor' }],
    ['POST', '/api/v1/libraries/31/access', { accessLevel: 'editor' }],
  ] as const)('enforces library access on %s %s', async (method, url, access) => {
    db.query.userLibraryAccess.findFirst.mockResolvedValue(access);
    const response = await app.inject({ method, url });
    expect(response.statusCode).toBe(403);
    expect(libraryService.findOne).not.toHaveBeenCalled();
    expect(libraryService.update).not.toHaveBeenCalled();
    expect(libraryService.remove).not.toHaveBeenCalled();
    expect(libraryService.grantAccess).not.toHaveBeenCalled();
    expect(auditEvents.emit).not.toHaveBeenCalled();
  });
  it('creates a validated library for the caller and audits the returned identity', async () => {
    libraryService.create.mockResolvedValue(library);
    const response = await app.inject({
      method: 'POST',
      url: '/api/v1/libraries',
      payload: { name: 'Reading', icon: ' book ', folders: ['/library/books'] },
    });
    expect(response.statusCode).toBe(201);
    expect(response.json()).toEqual(library);
    expect(libraryService.create).toHaveBeenCalledWith({ name: 'Reading', icon: 'book', folders: ['/library/books'] }, actor.id);
    expectAudit(AuditAction.LibraryCreate, "Created library 'Reading'");
  });
  it.each([
    { name: 'Reading', icon: 'book', folders: ['/library/books'], userId: 99 },
    { name: 'Reading', icon: 'book', folders: [] },
    { name: 'Reading', icon: 'book', folders: ['/library/books'], fileWriteEnabled: 'true' },
  ])('rejects malformed or caller-controlled create input %j', async (payload) => {
    const response = await app.inject({ method: 'POST', url: '/api/v1/libraries', payload });
    expect(response.statusCode).toBe(400);
    expect(libraryService.create).not.toHaveBeenCalled();
    expect(auditEvents.emit).not.toHaveBeenCalled();
  });
  it('updates library settings and deletes with a bodyless response and distinct audits', async () => {
    libraryService.update.mockResolvedValue({ ...library, watch: false });
    const update = await app.inject({ method: 'PATCH', url: '/api/v1/libraries/31', payload: { watch: false } });
    expect(update.json()).toEqual({ ...library, watch: false });
    expect(libraryService.update).toHaveBeenCalledWith(31, { watch: false });
    expectAudit(AuditAction.LibraryUpdate, 'Updated library #31');
    auditEvents.emit.mockClear();
    const remove = await app.inject({ method: 'DELETE', url: '/api/v1/libraries/31' });
    expect(remove.statusCode).toBe(204);
    expect(remove.body).toBe('');
    expect(libraryService.remove).toHaveBeenCalledWith(31);
    expectAudit(AuditAction.LibraryDelete, 'Deleted library #31');
  });
  it('returns service access denial without reporting a successful mutation', async () => {
    libraryService.update.mockRejectedValue(new ForbiddenException('Library is locked'));
    const response = await app.inject({ method: 'PATCH', url: '/api/v1/libraries/31', payload: { watch: false } });
    expect(response.statusCode).toBe(403);
    expect(auditEvents.emit).not.toHaveBeenCalled();
  });
  it('returns access records and audits grant, update, and revoke with library and target user identities', async () => {
    const access = { userId: 19, libraryId: 31, accessLevel: 'viewer' };
    libraryService.getAccess.mockResolvedValue([access]);
    libraryService.grantAccess.mockResolvedValue(access);
    const list = await app.inject({ method: 'GET', url: '/api/v1/libraries/31/access' });
    expect(list.json()).toEqual([access]);
    expect(libraryService.getAccess).toHaveBeenCalledWith(31);
    const grant = await app.inject({ method: 'POST', url: '/api/v1/libraries/31/access', payload: { userId: 19, accessLevel: 'viewer' } });
    expect(grant.statusCode).toBe(201);
    expect(grant.json()).toEqual(access);
    expect(libraryService.grantAccess).toHaveBeenCalledWith(31, { userId: 19, accessLevel: 'viewer' });
    expectAudit(AuditAction.LibraryAccessGrant, 'Granted library #31 access to user #19');
    auditEvents.emit.mockClear();
    libraryService.updateAccess.mockResolvedValue({ ...access, accessLevel: 'editor' });
    const update = await app.inject({ method: 'PATCH', url: '/api/v1/libraries/31/access/19', payload: { accessLevel: 'editor' } });
    expect(update.json()).toEqual({ ...access, accessLevel: 'editor' });
    expect(libraryService.updateAccess).toHaveBeenCalledWith(31, 19, 'editor');
    expectAudit(AuditAction.LibraryAccessUpdate, 'Updated library #31 access for user #19');
    auditEvents.emit.mockClear();
    const revoke = await app.inject({ method: 'DELETE', url: '/api/v1/libraries/31/access/19' });
    expect(revoke.statusCode).toBe(204);
    expect(revoke.body).toBe('');
    expect(libraryService.revokeAccess).toHaveBeenCalledWith(31, 19);
    expectAudit(AuditAction.LibraryAccessRevoke, 'Revoked library #31 access from user #19');
  });
  it.each([
    ['POST', '/api/v1/libraries/31/access', { userId: '19\nforged', accessLevel: 'viewer' }],
    ['POST', '/api/v1/libraries/31/access', { userId: 19, accessLevel: 'administrator' }],
    ['PATCH', '/api/v1/libraries/31/access/19', { accessLevel: 'editor', userId: 99 }],
    ['DELETE', '/api/v1/libraries/31/access/19%0Aforged', undefined],
  ] as const)('rejects unsafe identity or invalid access input on %s %s', async (method, url, payload) => {
    const response = await app.inject({ method, url, payload });
    expect(response.statusCode).toBe(400);
    expect(libraryService.grantAccess).not.toHaveBeenCalled();
    expect(libraryService.updateAccess).not.toHaveBeenCalled();
    expect(libraryService.revokeAccess).not.toHaveBeenCalled();
    expect(auditEvents.emit).not.toHaveBeenCalled();
  });
  it('validates admin prescan and reorder contracts', async () => {
    libraryService.prescan.mockResolvedValue({ bookCount: 3 });
    const scan = await app.inject({ method: 'POST', url: '/api/v1/libraries/prescan', payload: { libraryId: 31, paths: ['/library/books'] } });
    expect(scan.json()).toEqual({ bookCount: 3 });
    expect(libraryService.prescan).toHaveBeenCalledWith({ libraryId: 31, paths: ['/library/books'] });
    const reorder = await app.inject({ method: 'POST', url: '/api/v1/libraries/reorder', payload: { order: [{ id: 31, displayOrder: 0 }] } });
    expect(reorder.statusCode).toBe(204);
    expect(reorder.body).toBe('');
    expect(libraryService.reorder).toHaveBeenCalledWith({ order: [{ id: 31, displayOrder: 0 }] });
    const invalid = await app.inject({ method: 'POST', url: '/api/v1/libraries/reorder', payload: { order: [{ id: 31, displayOrder: -1 }] } });
    expect(invalid.statusCode).toBe(400);
    expect(libraryService.reorder).toHaveBeenCalledTimes(1);
  });
  it('transforms bounded move destination and folder queries and passes the caller', async () => {
    const page = { items: [], total: 0, page: 2, size: 20 };
    libraryService.findMoveDestinations.mockResolvedValue(page);
    libraryService.findMoveFolders.mockResolvedValue(page);
    const destinations = await app.inject({
      method: 'GET',
      url: '/api/v1/libraries/move-destinations?sourceLibraryId=31&page=2&size=20&q=%20fiction%20',
    });
    const folders = await app.inject({ method: 'GET', url: '/api/v1/libraries/31/move-folders?page=2&size=20' });
    expect(destinations.json()).toEqual(page);
    expect(folders.json()).toEqual(page);
    expect(libraryService.findMoveDestinations).toHaveBeenCalledWith({ sourceLibraryId: 31, page: 2, size: 20, q: 'fiction' }, actor);
    expect(libraryService.findMoveFolders).toHaveBeenCalledWith(31, { page: 2, size: 20 }, actor);
    const invalid = await app.inject({ method: 'GET', url: '/api/v1/libraries/31/move-folders?size=101' });
    expect(invalid.statusCode).toBe(400);
    expect(libraryService.findMoveFolders).toHaveBeenCalledTimes(1);
  });
  it('preserves paginated book and jump bucket responses with validated defaults', async () => {
    const page = { items: [{ id: 101, title: 'Book' }], total: 90000, page: 0, size: 50 };
    const buckets = { buckets: [{ label: 'A', offset: 0 }], total: 90000 };
    bookService.queryForLibrary.mockResolvedValue(page);
    bookService.queryJumpBucketsForLibrary.mockResolvedValue(buckets);
    const books = await app.inject({ method: 'POST', url: '/api/v1/libraries/31/books', payload: {} });
    const jumps = await app.inject({ method: 'POST', url: '/api/v1/libraries/31/books/jump-buckets', payload: {} });
    expect(books.json()).toEqual(page);
    expect(jumps.json()).toEqual(buckets);
    expect(bookService.queryForLibrary).toHaveBeenCalledWith(actor, 31, { sort: [], pagination: { page: 0, size: 50 } });
    expect(bookService.queryJumpBucketsForLibrary).toHaveBeenCalledWith(actor, 31, { sort: [], pagination: { page: 0, size: 50 }, maxBuckets: 32 });
    const invalid = await app.inject({ method: 'POST', url: '/api/v1/libraries/31/books', payload: { pagination: { page: 0, size: 201 } } });
    expect(invalid.statusCode).toBe(400);
    expect(bookService.queryForLibrary).toHaveBeenCalledTimes(1);
  });
  it('rejects books-only operations on podcast libraries', async () => {
    db.query.libraries.findFirst.mockResolvedValue({ type: 'podcasts' });
    const response = await app.inject({ method: 'POST', url: '/api/v1/libraries/31/books', payload: {} });
    expect(response.statusCode).toBe(400);
    expect(bookService.queryForLibrary).not.toHaveBeenCalled();
  });
  it('returns stats and job state and audits the accepted added-at recompute', async () => {
    libraryService.getStats.mockResolvedValue({ totalBooks: 90000 });
    addedAtService.get.mockResolvedValue({ status: 'idle' });
    addedAtService.start.mockResolvedValue({ status: 'running', libraryId: 31 });
    const stats = await app.inject({ method: 'GET', url: '/api/v1/libraries/31/stats' });
    const current = await app.inject({ method: 'GET', url: '/api/v1/libraries/31/recompute-added-at' });
    const started = await app.inject({ method: 'POST', url: '/api/v1/libraries/31/recompute-added-at' });
    expect(stats.json()).toEqual({ totalBooks: 90000 });
    expect(current.json()).toEqual({ status: 'idle' });
    expect(started.statusCode).toBe(202);
    expect(started.json()).toEqual({ status: 'running', libraryId: 31 });
    expect(libraryService.getStats).toHaveBeenCalledWith(31);
    expect(addedAtService.get).toHaveBeenCalledWith(31, actor);
    expect(addedAtService.start).toHaveBeenCalledWith(31, actor);
    expectAudit(AuditAction.LibraryRecomputeAddedAt, 'Started added_at recompute for library #31');
  });
  it('returns a bounded rename preview and explicit running state', async () => {
    const preview = { items: [], total: 90000, page: 2, pageSize: 20, previewToken };
    bulkRenameService.getPreview.mockResolvedValue(preview);
    bulkRenameService.isRunning.mockReturnValue(true);
    const response = await app.inject({
      method: 'GET',
      url: '/api/v1/libraries/31/bulk-rename/preview?page=2&pageSize=20&status=will_rename&search=%20fiction%20',
    });
    const status = await app.inject({ method: 'GET', url: '/api/v1/libraries/31/bulk-rename/status' });
    expect(response.json()).toEqual(preview);
    expect(status.json()).toEqual({ running: true });
    expect(bulkRenameService.getPreview).toHaveBeenCalledWith(31, 2, 20, 'will_rename', 'fiction');
    expect(bulkRenameService.isRunning).toHaveBeenCalledWith(31);
    const invalid = await app.inject({ method: 'GET', url: '/api/v1/libraries/31/bulk-rename/preview?pageSize=201' });
    expect(invalid.statusCode).toBe(400);
    expect(bulkRenameService.getPreview).toHaveBeenCalledTimes(1);
  });
  it('streams scoped bulk rename progress and completion and audits the library', async () => {
    bulkRenameService.execute.mockImplementation((_libraryId, _userId, options) => {
      expect(options.isCancelled()).toBe(false);
      options.onProgress({ bookId: 101, status: 'success' });
      return Promise.resolve(summary);
    });
    const response = await app.inject({
      method: 'POST',
      url: '/api/v1/libraries/31/bulk-rename/execute',
      payload: { previewToken, includeBookIds: [101] },
    });
    expect(response.statusCode).toBe(200);
    expect(response.headers['content-type']).toBe('text/event-stream');
    expect(
      response.body
        .split('\n\n')
        .filter(Boolean)
        .map((frame) => JSON.parse(frame.slice(6))),
    ).toEqual([
      { bookId: 101, status: 'success' },
      { done: true, ...summary },
    ]);
    expect(bulkRenameService.execute).toHaveBeenCalledWith(
      31,
      actor.id,
      expect.objectContaining({ previewToken, includeBookIds: [101], excludeBookIds: undefined }),
    );
    expectAudit(AuditAction.LibraryBulkRename, 'Bulk renamed books in library #31');
  });
  it('streams metadata write dry-run completion and audits the caller and library', async () => {
    libraryService.writeMetadataToFiles.mockImplementation((_libraryId, _userId, _dryRun, options) => {
      expect(options.isCancelled()).toBe(false);
      return Promise.resolve(summary);
    });
    const response = await app.inject({ method: 'POST', url: '/api/v1/libraries/31/write-metadata-to-files?dryRun=true' });
    expect(response.statusCode).toBe(200);
    expect(response.headers['content-type']).toBe('text/event-stream');
    expect(JSON.parse(response.body.slice(6))).toEqual({ done: true, ...summary });
    expect(libraryService.writeMetadataToFiles).toHaveBeenCalledWith(31, actor.id, true, expect.any(Object));
    expectAudit(AuditAction.LibraryWriteMetadataToFiles, 'Wrote metadata to files for library #31');
  });
  it('rejects conflicting rename selections before streaming or auditing', async () => {
    const response = await app.inject({
      method: 'POST',
      url: '/api/v1/libraries/31/bulk-rename/execute',
      payload: { previewToken, includeBookIds: [101], excludeBookIds: [102] },
    });
    expect(response.statusCode).toBe(400);
    expect(bulkRenameService.execute).not.toHaveBeenCalled();
    expect(auditEvents.emit).not.toHaveBeenCalled();
  });
});
