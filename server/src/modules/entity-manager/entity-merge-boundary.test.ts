import { EMPTY_CONTENT_FILTER_RULES, type EntityType } from '@bookorbit/types';
import { BadRequestException, ValidationPipe } from '@nestjs/common';
import { Test } from '@nestjs/testing';

import type { RequestUser } from '../../common/types/request-user';
import { MergeEntitiesDto } from './dto/entity-manager.dto';
import { EntityManagerController } from './entity-manager.controller';
import { EntityManagerService } from './entity-manager.service';

describe('entity merge input boundary', () => {
  const user: RequestUser = { id: 1, username: 'editor', isSuperuser: false, permissions: [], contentFilters: EMPTY_CONTENT_FILTER_RULES };
  const pipe = new ValidationPipe({ whitelist: true, forbidNonWhitelisted: true, transform: true });
  const metadata = { type: 'body' as const, metatype: MergeEntitiesDto };
  let controller: EntityManagerController;
  let service: { merge: ReturnType<typeof vi.fn> };

  beforeEach(async () => {
    service = { merge: vi.fn().mockResolvedValue({ targetId: 1, mergedIds: [2], affectedBookCount: 1 }) };
    const module = await Test.createTestingModule({
      providers: [
        { provide: EntityManagerService, useValue: service },
        {
          provide: EntityManagerController,
          useFactory: (manager: EntityManagerService) => new EntityManagerController(manager),
          inject: [EntityManagerService],
        },
      ],
    }).compile();
    controller = module.get(EntityManagerController);
  });

  async function merge(entityType: EntityType, body: unknown) {
    const dto: MergeEntitiesDto = await pipe.transform(body, metadata);
    return controller.merge(entityType, dto, user);
  }

  it.each([
    {},
    { targetEntityId: 1 },
    { sourceEntityIds: [2] },
    { targetEntityId: null, sourceEntityIds: [2] },
    { targetEntityId: 1, sourceEntityIds: null },
    { targetEntityId: '1', sourceEntityIds: [2] },
    { targetEntityId: 1.5, sourceEntityIds: [2] },
    { targetEntityId: 1, sourceEntityIds: '2' },
    { targetEntityId: 1, sourceEntityIds: ['2'] },
    { targetEntityId: 1, sourceEntityIds: [2.5] },
    { targetEntityId: 1, sourceEntityIds: [] },
    { targetEntityId: 1, sourceEntityIds: [2], writeFiles: 'false' },
    { targetValue: 'Publisher A', sourceValues: ['Publisher B'] },
  ])('rejects malformed author merge %j before any mutation', async (body) => {
    await expect(merge('author', body)).rejects.toThrow(BadRequestException);
    expect(service.merge).not.toHaveBeenCalled();
  });

  it.each([
    { targetValue: 'Publisher A' },
    { sourceValues: ['Publisher B'] },
    { targetValue: 1, sourceValues: ['Publisher B'] },
    { targetValue: 'Publisher A', sourceValues: [2] },
    { targetValue: 'Publisher A', sourceValues: null },
    { targetEntityId: 1, sourceEntityIds: [2] },
  ])('rejects malformed inline merge %j before any mutation', async (body) => {
    await expect(merge('publisher', body)).rejects.toThrow(BadRequestException);
    expect(service.merge).not.toHaveBeenCalled();
  });

  it.each<EntityType>(['author', 'genre', 'tag', 'narrator', 'series'])('preserves valid numeric merge for %s', async (entityType) => {
    await merge(entityType, { targetEntityId: 1, sourceEntityIds: [2], writeFiles: false });
    expect(service.merge).toHaveBeenCalledWith(entityType, user, 1, [2], false);
  });

  it.each<EntityType>(['publisher', 'language'])('preserves valid inline merge for %s', async (entityType) => {
    await merge(entityType, { targetValue: 'Target', sourceValues: ['Source'], writeFiles: false });
    expect(service.merge).toHaveBeenCalledWith(entityType, user, 'Target', ['Source'], false);
  });

  it('preserves optional file writing', async () => {
    await merge('author', { targetEntityId: 1, sourceEntityIds: [2] });
    expect(service.merge).toHaveBeenCalledWith('author', user, 1, [2], false);
  });
});
