import { CanActivate, ExecutionContext, ForbiddenException, Injectable, NotFoundException } from '@nestjs/common';
import type { FastifyRequest } from 'fastify';
import type { RequestUser } from '../../common/types/request-user';
import { MigrationRepository } from './migration.repository';

@Injectable()
export class MigrationAccessGuard implements CanActivate {
  constructor(private readonly repo: MigrationRepository) {}

  async canActivate(context: ExecutionContext): Promise<boolean> {
    const request = context.switchToHttp().getRequest<FastifyRequest & { user: RequestUser }>();
    const user = request.user;
    if (user.isSuperuser) return true;
    const body = (request.body ?? {}) as Record<string, unknown>;
    const params = (request.params ?? {}) as Record<string, unknown>;
    const path = request.routeOptions.url ?? request.url;
    const id = Number(params.id);
    let row: { createdByUserId?: number | null; triggeredByUserId?: number | null; profileId?: number; userMappings?: unknown } | undefined;
    if (path.includes('/sources/:id')) row = await this.repo.findSourceById(id);
    else if (path.includes('/plans/:id')) row = await this.repo.findPlanArtifactOwnershipById(id);
    else if (path.includes('/runs/:id')) row = await this.repo.findRunById(id);
    else if (typeof body.sourceId === 'number') row = await this.repo.findSourceById(body.sourceId);
    else if (typeof body.profileId === 'number') row = await this.repo.findProfileById(body.profileId);
    else if (typeof body.planArtifactId === 'number') row = await this.repo.findPlanArtifactOwnershipById(body.planArtifactId);
    const hasReference = path.includes('/:id') || ['sourceId', 'profileId', 'planArtifactId'].some((key) => key in body);
    if (hasReference && !row) throw new NotFoundException('Migration resource not found');
    if (row && (row.createdByUserId ?? row.triggeredByUserId) !== user.id) {
      throw new ForbiddenException('Migration belongs to another user');
    }
    const storedMappings = row?.profileId ? (await this.repo.findProfileById(row.profileId))?.userMappings : row?.userMappings;
    const mappings = Array.isArray(body.userMappings) ? body.userMappings : storedMappings;
    if (
      Array.isArray(mappings) &&
      mappings.some((mapping: unknown) => {
        if (!mapping || typeof mapping !== 'object') return false;
        const target = (mapping as { targetUserId?: number | null }).targetUserId;
        return target != null && target !== user.id;
      })
    ) {
      throw new ForbiddenException("Only superusers may migrate another user's reading data");
    }
    return true;
  }
}
