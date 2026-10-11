import { ForbiddenException } from '@nestjs/common';

import type { RequestUser } from '../../../common/types/request-user';

export function assertMigrationOwner(ownerUserId: number | null, user: RequestUser): void {
  if (!user.isSuperuser && ownerUserId !== user.id) {
    throw new ForbiddenException('Migration belongs to another user');
  }
}

export function assertMigrationUserMappings(mappings: unknown, user: RequestUser): void {
  if (user.isSuperuser || !Array.isArray(mappings)) return;
  for (const mapping of mappings) {
    if (!mapping || typeof mapping !== 'object') continue;
    const targetUserId = (mapping as { targetUserId?: number | null }).targetUserId;
    if (targetUserId != null && targetUserId !== user.id) {
      throw new ForbiddenException("Only superusers may migrate another user's reading data");
    }
  }
}
