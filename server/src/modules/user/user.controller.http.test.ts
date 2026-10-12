import fastifyMultipart from '@fastify/multipart';
import {
  AuditAction,
  AuditResource,
  Permission,
  type UserListSummary,
  type UserAttentionResponse,
  type ContentFilterRulesWithNames,
} from '@bookorbit/types';
import { UnauthorizedException, ValidationPipe, type ExecutionContext } from '@nestjs/common';
import { Reflector } from '@nestjs/core';
import { FastifyAdapter, type NestFastifyApplication } from '@nestjs/platform-fastify';
import { Test } from '@nestjs/testing';

import { PermissionGuard } from '../../common/guards/permission.guard';
import { AuditInterceptor } from '../../common/interceptors/audit.interceptor';
import { PermissionService } from '../../common/services/permission.service';
import type { RequestUser } from '../../common/types/request-user';
import { AUDIT_EVENT, AuditEventsService } from '../audit/audit-events.service';
import { UserAvatarService } from './user-avatar.service';
import { UserController } from './user.controller';
import { UserService } from './user.service';

const account = {
  id: 7,
  username: 'reader',
  name: 'Reader',
  email: null,
  active: true,
  isSuperuser: false,
  isDefaultPassword: false,
  tokenVersion: 1,
  settings: {},
  avatarUrl: null,
  provisioningMethod: 'local',
  permissions: [],
  contentFilters: { includeTagIds: [], excludeTagIds: [], includeGenreIds: [], excludeGenreIds: [] },
} as RequestUser;
const actors: Record<string, RequestUser> = {
  reader: account,
  admin: { ...account, id: 11, username: 'user-admin', permissions: [Permission.ManageUsers] },
  librarian: { ...account, id: 12, permissions: [Permission.ManageLibraries] },
  superuser: { ...account, id: 1, username: 'root', isSuperuser: true },
  demo: { ...account, isSuperuser: true, permissions: [Permission.DemoRestricted] },
};
const service = {
  findAll: vi.fn(),
  summary: vi.fn(),
  findNeedingAttention: vi.fn(),
  findAssignable: vi.fn(),
  findById: vi.fn(),
  updateMe: vi.fn(),
  updateMySettings: vi.fn(),
  updateReaderStorageMode: vi.fn(),
  updateThemeStorageMode: vi.fn(),
  updateSeriesCollapsePreferences: vi.fn(),
  createUser: vi.fn(),
  createSharedUser: vi.fn(),
  updateUser: vi.fn(),
  deleteUser: vi.fn(),
  setPermissions: vi.fn(),
  setSuperuser: vi.fn(),
  getLibraryIds: vi.fn(),
  setLibraries: vi.fn(),
  adminResetPassword: vi.fn(),
  unlockUser: vi.fn(),
  getContentFilters: vi.fn(),
  setContentFilters: vi.fn(),
};
const avatars = { uploadOwnAvatar: vi.fn(), removeOwnAvatar: vi.fn(), getAvatarPath: vi.fn() };
const auditEvents = { emit: vi.fn() };
function expectAudit(actor: RequestUser, resourceId: number, action: AuditAction, description: string) {
  expect(auditEvents.emit).toHaveBeenCalledExactlyOnceWith(AUDIT_EVENT, {
    userId: actor.id,
    actorUsername: actor.username,
    action,
    resource: AuditResource.User,
    resourceId,
    description,
    ip: '127.0.0.1',
  });
}
type HttpMethod = 'GET' | 'POST' | 'PATCH' | 'PUT' | 'DELETE';
const adminWrites: {
  method: HttpMethod;
  path: string;
  payload?: object;
  status: number;
  methodName: keyof typeof service;
  args: unknown[];
  action: AuditAction;
  description: string;
}[] = [
  {
    method: 'PATCH',
    path: '/29',
    payload: { name: 'Updated' },
    status: 200,
    methodName: 'updateUser',
    args: [29, { name: 'Updated' }, actors.admin],
    action: AuditAction.UserUpdate,
    description: 'Updated user #29',
  },
  {
    method: 'DELETE',
    path: '/29',
    status: 204,
    methodName: 'deleteUser',
    args: [29, actors.admin],
    action: AuditAction.UserDelete,
    description: 'Deleted user #29',
  },
  {
    method: 'PUT',
    path: '/29/permissions',
    payload: { permissionNames: [Permission.LibraryDownload] },
    status: 204,
    methodName: 'setPermissions',
    args: [29, { permissionNames: [Permission.LibraryDownload] }, actors.admin],
    action: AuditAction.UserPermissionSet,
    description: 'Updated permissions for user #29',
  },
  {
    method: 'PUT',
    path: '/29/libraries',
    payload: { libraryIds: [3, 5] },
    status: 204,
    methodName: 'setLibraries',
    args: [29, [3, 5], actors.admin],
    action: AuditAction.UserUpdate,
    description: 'Updated library access for user #29',
  },
  {
    method: 'POST',
    path: '/29/reset-password',
    status: 201,
    methodName: 'adminResetPassword',
    args: [29, actors.admin],
    action: AuditAction.AuthPasswordAdminReset,
    description: 'Admin reset password for user #29',
  },
  {
    method: 'POST',
    path: '/29/unlock',
    status: 201,
    methodName: 'unlockUser',
    args: [29, actors.admin],
    action: AuditAction.UserUnlock,
    description: 'Cleared login lockout for user #29',
  },
  {
    method: 'PUT',
    path: '/29/content-filters',
    payload: { includeTagIds: [2], seeOwnRequestedBooks: true },
    status: 204,
    methodName: 'setContentFilters',
    args: [29, { includeTagIds: [2], seeOwnRequestedBooks: true }, actors.admin],
    action: AuditAction.UserContentFiltersSet,
    description: 'Updated content filters for user #29',
  },
];

describe('UserController HTTP account and administration contracts', () => {
  let app: NestFastifyApplication;
  beforeAll(async () => {
    const module = await Test.createTestingModule({
      controllers: [UserController],
      providers: [
        { provide: UserService, useValue: service },
        { provide: UserAvatarService, useValue: avatars },
        { provide: AuditEventsService, useValue: auditEvents },
      ],
    }).compile();
    app = module.createNestApplication<NestFastifyApplication>(new FastifyAdapter());
    app.setGlobalPrefix('api/v1');
    app.useGlobalPipes(new ValidationPipe({ whitelist: true, forbidNonWhitelisted: true, transform: true }));
    const reflector = module.get(Reflector);
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
      new PermissionGuard(reflector, new PermissionService()),
    );
    app.useGlobalInterceptors(new AuditInterceptor(reflector, module.get(AuditEventsService)));
    await app.register(fastifyMultipart);
    await app.init();
    await app.getHttpAdapter().getInstance().ready();
  });
  beforeEach(() => vi.resetAllMocks());
  afterAll(async () => app?.close());
  function request(method: HttpMethod, path: string, actor = 'admin', payload?: object) {
    return app.inject({ method, url: `/api/v1/users${path}`, headers: { authorization: actor }, payload });
  }

  it('requires authentication before account reads and writes', async () => {
    expect((await request('GET', '/me/content-filters', 'unknown')).statusCode).toBe(401);
    expect((await request('PATCH', '/me', 'unknown', { name: 'Changed' })).statusCode).toBe(401);
    expect(service.getContentFilters).not.toHaveBeenCalled();
    expect(service.updateMe).not.toHaveBeenCalled();
    expect(auditEvents.emit).not.toHaveBeenCalled();
  });
  it.each([
    ['/summary', 'summary', { total: 4, admins: 1, active: 3, inactive: 1, attention: 1 } satisfies UserListSummary],
    [
      '/attention',
      'findNeedingAttention',
      {
        items: [
          {
            id: 29,
            username: 'pending',
            name: 'Pending',
            avatarUrl: null,
            provisioningMethod: 'local',
            reason: 'neverSignedIn',
            lockedUntil: null,
            createdAt: '2026-01-01T00:00:00.000Z',
            resetLinkExpiresAt: null,
          },
        ],
        total: 1,
      } satisfies UserAttentionResponse,
    ],
  ] as const)('allows user administrators to read %s and blocks other roles', async (path, methodName, result) => {
    service[methodName].mockResolvedValue(result);
    const response = await request('GET', path);
    expect(response.statusCode).toBe(200);
    expect(response.json()).toEqual(result);
    for (const actor of ['reader', 'librarian']) expect((await request('GET', path, actor)).statusCode).toBe(403);
    expect(service[methodName]).toHaveBeenCalledTimes(1);
    expect(service.findById).not.toHaveBeenCalled();
  });
  it('requires library management permission to list assignable users', async () => {
    const users = [{ id: 29, username: 'available' }];
    service.findAssignable.mockResolvedValue(users);
    const response = await request('GET', '/assignable', 'librarian');
    expect(response.statusCode).toBe(200);
    expect(response.json()).toEqual(users);
    expect((await request('GET', '/assignable', 'admin')).statusCode).toBe(403);
    expect((await request('GET', '/assignable', 'reader')).statusCode).toBe(403);
    expect(service.findAssignable).toHaveBeenCalledTimes(1);
  });
  it('transforms bounded pagination and rejects oversized or unexpected query fields', async () => {
    service.findAll.mockResolvedValue({ items: [], total: 0 });
    expect((await request('GET', '?page=2&pageSize=25&search=alice')).statusCode).toBe(200);
    expect(service.findAll).toHaveBeenCalledWith(
      expect.objectContaining({ page: 2, pageSize: 25, search: 'alice', sortBy: 'username', sortDir: 'asc' }),
    );
    expect((await request('GET', '?pageSize=101')).statusCode).toBe(400);
    expect((await request('GET', '?userId=29')).statusCode).toBe(400);
    expect(service.findAll).toHaveBeenCalledTimes(1);
  });
  it('creates a user and audits persisted identity without recording generated secrets', async () => {
    const payload = { username: 'requested', name: 'Requested User', email: 'reader@example.test' };
    const created = {
      id: 29,
      username: 'persisted',
      name: 'Requested User',
      resetUrl: 'https://bookorbit.test/reset-password?token=private-generated-token',
    } satisfies Awaited<ReturnType<UserService['createUser']>>;
    service.createUser.mockResolvedValue(created);
    const response = await request('POST', '', 'admin', payload);
    expect(response.statusCode).toBe(201);
    expect(response.json()).toEqual(created);
    expect(service.createUser).toHaveBeenCalledWith(payload);
    expectAudit(actors.admin, 29, AuditAction.UserCreate, "Created user 'persisted'");
    expect(JSON.stringify(auditEvents.emit.mock.calls)).not.toContain('private-generated-token');
  });
  it('rejects shared-account creation by non-superuser administrators and audits successful creation', async () => {
    const payload = { username: 'shared', name: 'Shared Account', libraryIds: [3] };
    expect((await request('POST', '/shared', 'admin', payload)).statusCode).toBe(403);
    expect(service.createSharedUser).not.toHaveBeenCalled();
    expect(auditEvents.emit).not.toHaveBeenCalled();
    const shared = { id: 31, username: 'shared', name: 'Shared Account' } satisfies Awaited<ReturnType<UserService['createSharedUser']>>;
    service.createSharedUser.mockResolvedValue(shared);
    const response = await request('POST', '/shared', 'superuser', payload);
    expect(response.statusCode).toBe(201);
    expect(response.json()).toEqual(shared);
    expect(service.createSharedUser).toHaveBeenCalledWith(payload);
    expectAudit(actors.superuser, 31, AuditAction.UserCreate, "Created shared user 'shared'");
  });
  it('uses the authenticated account for profile updates and audit identity', async () => {
    service.updateMe.mockResolvedValue({ id: account.id, name: 'Changed' });
    const response = await request('PATCH', '/me', 'reader', { name: 'Changed' });
    expect(response.statusCode).toBe(200);
    expect(response.json()).toEqual({ id: 7, name: 'Changed' });
    expect(service.updateMe).toHaveBeenCalledWith(7, { name: 'Changed' });
    expectAudit(account, 7, AuditAction.UserSelfUpdate, 'User updated their own profile');
  });
  it.each([
    ['PATCH', '/me', { name: 'Changed' }],
    ['PATCH', '/me/reader-storage-mode', { sync: true }],
    ['PATCH', '/me/theme-storage-mode', { sync: true }],
    ['POST', '/me/avatar', undefined],
    ['DELETE', '/me/avatar', undefined],
  ] as const)('enforces demo restrictions for %s %s even for a superuser', async (method, path, payload) => {
    expect((await request(method, path, 'demo', payload)).statusCode).toBe(403);
    for (const operation of Object.values(service)) expect(operation).not.toHaveBeenCalled();
    for (const operation of Object.values(avatars)) expect(operation).not.toHaveBeenCalled();
    expect(auditEvents.emit).not.toHaveBeenCalled();
  });
  it('passes authenticated settings and series preferences with documented no-content responses', async () => {
    const settings = { settings: { dashboardConfig: { readingGoal: 12 } } };
    service.updateMySettings.mockResolvedValue({ id: 7, ...settings });
    const response = await request('PATCH', '/me/settings', 'reader', settings);
    expect(response.statusCode).toBe(200);
    expect(response.json()).toEqual({ id: 7, ...settings });
    expect(service.updateMySettings).toHaveBeenCalledWith(account, settings);
    const preferences = { global: true, libraries: { '3': false, '5': null }, authorPages: false };
    const preferenceResponse = await request('PATCH', '/me/series-collapse-preferences', 'reader', preferences);
    expect(preferenceResponse.statusCode).toBe(204);
    expect(preferenceResponse.body).toBe('');
    expect(service.updateSeriesCollapsePreferences).toHaveBeenCalledWith(7, preferences);
    for (const [path, methodName] of [
      ['reader', 'updateReaderStorageMode'],
      ['theme', 'updateThemeStorageMode'],
    ] as const) {
      const modeResponse = await request('PATCH', `/me/${path}-storage-mode`, 'reader', { sync: false });
      expect(modeResponse.statusCode).toBe(204);
      expect(modeResponse.body).toBe('');
      expect(service[methodName]).toHaveBeenCalledWith(7, false);
    }
  });
  it('audits multipart avatar upload and removal against the authenticated account', async () => {
    const payload = Buffer.from(
      '--avatar-boundary\r\nContent-Disposition: form-data; name="file"; filename="avatar.png"\r\nContent-Type: image/png\r\n\r\npicture-bytes\r\n--avatar-boundary--\r\n',
    );
    avatars.uploadOwnAvatar.mockResolvedValue({ avatarUrl: '/api/v1/users/7/avatar' });
    const response = await app.inject({
      method: 'POST',
      url: '/api/v1/users/me/avatar',
      headers: { authorization: 'reader', 'content-type': 'multipart/form-data; boundary=avatar-boundary' },
      payload,
    });
    expect(response.statusCode).toBe(201);
    expect(response.json()).toEqual({ avatarUrl: '/api/v1/users/7/avatar' });
    expect(avatars.uploadOwnAvatar).toHaveBeenCalledWith(account, Buffer.from('picture-bytes'), 'image/png');
    expectAudit(account, 7, AuditAction.UserSelfUpdate, 'User uploaded a profile picture');
    auditEvents.emit.mockClear();
    avatars.removeOwnAvatar.mockResolvedValue({ avatarUrl: null });
    expect((await request('DELETE', '/me/avatar', 'reader')).json()).toEqual({ avatarUrl: null });
    expect(avatars.removeOwnAvatar).toHaveBeenCalledWith(account);
    expectAudit(account, 7, AuditAction.UserSelfUpdate, 'User removed their profile picture');
  });
  it.each(adminWrites)(
    'checks permission, actor and audit identity for $method $path',
    async ({ method, path, payload, status, methodName, args, action, description }) => {
      expect((await request(method, path, 'reader', payload)).statusCode).toBe(403);
      expect(service[methodName]).not.toHaveBeenCalled();
      expect(auditEvents.emit).not.toHaveBeenCalled();
      const result =
        methodName === 'adminResetPassword'
          ? ({ resetUrl: 'https://bookorbit.test/reset-password?token=private-reset-token' } satisfies Awaited<
              ReturnType<UserService['adminResetPassword']>
            >)
          : methodName === 'unlockUser'
            ? ({ unlocked: true } satisfies Awaited<ReturnType<UserService['unlockUser']>>)
            : undefined;
      service[methodName].mockResolvedValue(result);
      const response = await request(method, path, 'admin', payload);
      expect(response.statusCode).toBe(status);
      if (status === 204) expect(response.body).toBe('');
      if (result) expect(response.json()).toEqual(result);
      expect(service[methodName]).toHaveBeenCalledWith(...args);
      expectAudit(actors.admin, 29, action, description);
      expect(JSON.stringify(auditEvents.emit.mock.calls)).not.toContain('private-reset-token');
    },
  );
  it.each([true, false])('audits superuser status %s using the route target and authenticated actor', async (enabled) => {
    expect((await request('PUT', '/29/superuser', 'reader', { isSuperuser: enabled })).statusCode).toBe(403);
    expect(service.setSuperuser).not.toHaveBeenCalled();
    const response = await request('PUT', '/29/superuser', 'superuser', { isSuperuser: enabled });
    expect(response.statusCode).toBe(204);
    expect(response.body).toBe('');
    expect(service.setSuperuser).toHaveBeenCalledWith(29, enabled, actors.superuser);
    expectAudit(
      actors.superuser,
      29,
      enabled ? AuditAction.UserSuperuserEnable : AuditAction.UserSuperuserDisable,
      `${enabled ? 'Enabled' : 'Disabled'} superuser for user #29`,
    );
  });
  it('scopes own content-filter reads to the actor and gates administrative reads', async () => {
    const filters = {
      includeTags: [{ id: 2, name: 'Fantasy' }],
      excludeTags: [],
      includeGenres: [],
      excludeGenres: [],
      seeOwnRequestedBooks: true,
    } satisfies ContentFilterRulesWithNames;
    service.getContentFilters.mockResolvedValue(filters);
    const own = await request('GET', '/me/content-filters', 'reader');
    expect(own.statusCode).toBe(200);
    expect(own.json()).toEqual(filters);
    expect(service.getContentFilters).toHaveBeenCalledWith(7, account);
    expect((await request('GET', '/29/content-filters', 'reader')).statusCode).toBe(403);
    const target = await request('GET', '/29/content-filters', 'admin');
    expect(target.statusCode).toBe(200);
    expect(target.json()).toEqual(filters);
    expect(service.getContentFilters).toHaveBeenCalledWith(29, actors.admin);
    expect(service.getContentFilters).toHaveBeenCalledTimes(2);
  });
  it.each([
    ['PATCH', '/me', { name: 'Changed', id: 29 }],
    ['PATCH', '/me/settings', { settings: {} }],
    ['PATCH', '/me/reader-storage-mode', { sync: 'true' }],
    ['PATCH', '/me/theme-storage-mode', { sync: 1 }],
    ['PATCH', '/me/series-collapse-preferences', { libraries: { '3': 'false' } }],
    ['POST', '', { username: 'alice', name: 'Alice', email: 'invalid' }],
    ['PATCH', '/29', { isSuperuser: true }],
    ['PUT', '/29/permissions', { permissionNames: ['unknown-permission'] }],
    ['PUT', '/29/libraries', { libraryIds: [-1] }],
    ['PUT', '/29/superuser', { isSuperuser: 'false' }],
    ['PUT', '/29/content-filters', { includeTagIds: ['2'] }],
    ['DELETE', '/not-a-number', undefined],
  ] as const)('rejects invalid %s %s input before service calls or successful audit events', async (method, path, payload) => {
    expect((await request(method, path, 'admin', payload)).statusCode).toBe(400);
    for (const operation of Object.values(service)) expect(operation).not.toHaveBeenCalled();
    expect(auditEvents.emit).not.toHaveBeenCalled();
  });
});
