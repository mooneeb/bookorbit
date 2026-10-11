import { BadRequestException, ConflictException, Injectable, InternalServerErrorException, NotFoundException } from '@nestjs/common';

import type { RequestUser } from '../../common/types/request-user';
import { CreateMigrationProfileDto } from './dto/create-migration-profile.dto';
import { ValidatePathMappingsDto } from './dto/validate-path-mappings.dto';
import { parseConnectionConfig } from './core/connection-config';
import { asRecord } from './core/coerce';
import { buildPathMappingsHash } from './core/plan-hash';
import { sanitizeProfileForApi } from './core/api-sanitizers';
import { MigrationEncryptionService } from './core/migration-encryption.service';
import { MigrationRepository } from './migration.repository';
import { SourceAdapterRegistry } from './adapters/source-adapter.registry';
import { PathMappingValidationService } from './planner/path-mapping-validation.service';
import { assertMigrationOwner, assertMigrationUserMappings } from './core/migration-access';

const ACTIVE_LIVE_STATES = new Set(['running']);

@Injectable()
export class MigrationProfileService {
  constructor(
    private readonly repo: MigrationRepository,
    private readonly adapterRegistry: SourceAdapterRegistry,
    private readonly pathValidator: PathMappingValidationService,
    private readonly encryption: MigrationEncryptionService,
  ) {}

  async listTargetUsers(user: RequestUser) {
    return this.repo.listTargetUsersForMapping(user.isSuperuser ? undefined : user.id);
  }

  async createProfile(dto: CreateMigrationProfileDto, user: RequestUser) {
    const source = await this.repo.findSourceById(dto.sourceId);
    if (!source) throw new NotFoundException(`Migration source not found: ${dto.sourceId}`);
    assertMigrationOwner(source.createdByUserId, user);
    assertMigrationUserMappings(dto.userMappings, user);
    await this.assertNoGlobalActiveRun();

    const targetUsers = await this.listTargetUsers(user);
    const knownTargetUserIds = new Set(targetUsers.map((row) => row.id));
    const requestedTargetUserIds = [...new Set(dto.userMappings.map((row) => row.targetUserId).filter((id): id is number => id !== null))];
    if (requestedTargetUserIds.length === 0) {
      throw new BadRequestException('Map at least one source user to a target user');
    }
    const unknownTargetUserIds = requestedTargetUserIds.filter((targetUserId) => !knownTargetUserIds.has(targetUserId));
    if (unknownTargetUserIds.length > 0) {
      throw new BadRequestException(`Invalid target user IDs in mapping: ${unknownTargetUserIds.join(', ')}`);
    }

    const payload = {
      sourceId: dto.sourceId,
      name: dto.name.trim(),
      userMappings: dto.userMappings,
      pathMappings: dto.pathMappings ?? [],
      scope: dto.scope ?? {},
      createdByUserId: user.id,
    } as const;

    const profile = await this.repo.createProfile({ ...payload });
    if (!profile) throw new InternalServerErrorException('Failed to save migration profile');
    await this.repo.purgeRunState(dto.sourceId);
    return sanitizeProfileForApi(profile);
  }

  async suggestUserMappings(sourceId: number, user: RequestUser) {
    const source = await this.repo.findSourceById(sourceId);
    if (!source) throw new NotFoundException(`Migration source not found: ${sourceId}`);
    assertMigrationOwner(source.createdByUserId, user);

    const adapter = this.adapterRegistry.get(source.type);
    const decryptedConfig = this.encryption.decryptConfig(source.connectionConfig);
    const sourceData = await adapter.exportData(parseConnectionConfig(source.type, decryptedConfig));
    const targetUsers = await this.listTargetUsers(user);

    const suggestions = sourceData.users.map((sourceUser: { sourceUserId: string; username: string; email: string | null; name: string | null }) => {
      const candidates = targetUsers
        .map((targetUser) => {
          const score = scoreUserMapping(sourceUser, targetUser);
          return {
            targetUserId: targetUser.id,
            username: targetUser.username,
            name: targetUser.name,
            email: targetUser.email,
            score,
            confidence: confidenceLabel(score),
          };
        })
        .filter((candidate) => candidate.score > 0)
        .sort((a, b) => b.score - a.score)
        .slice(0, 3);

      return {
        sourceUserId: sourceUser.sourceUserId,
        username: sourceUser.username,
        name: sourceUser.name,
        email: sourceUser.email,
        suggestedTargetUserId: candidates[0]?.targetUserId ?? null,
        confidence: candidates[0]?.confidence ?? null,
        candidates,
      };
    });

    return {
      sourceId,
      generatedAt: new Date().toISOString(),
      suggestions,
    };
  }

  async validatePathMappings(sourceId: number, dto: ValidatePathMappingsDto, user: RequestUser) {
    const source = await this.repo.findSourceById(sourceId);
    if (!source) throw new NotFoundException(`Migration source not found: ${sourceId}`);
    assertMigrationOwner(source.createdByUserId, user);

    const adapter = this.adapterRegistry.get(source.type);
    const decryptedConfig = this.encryption.decryptConfig(source.connectionConfig);
    const sourceData = await adapter.exportData(parseConnectionConfig(source.type, decryptedConfig));

    const validation = await this.pathValidator.validate({
      sourceBooks: sourceData.books,
      pathMappings: dto.pathMappings,
      actorUserId: user.id,
      sampleLimit: dto.sampleLimit,
    });

    const validatedAt = new Date().toISOString();
    const pathMappingsHash = buildPathMappingsHash(dto.pathMappings);
    const persistedProfileId = await this.persistPathValidation(sourceId, pathMappingsHash, validatedAt, user);

    return {
      sourceId,
      validatedAt,
      pathMappingsHash,
      persistedProfileId,
      ...validation,
    };
  }

  private async persistPathValidation(sourceId: number, pathMappingsHash: string, validatedAt: string, user: RequestUser): Promise<number | null> {
    const profiles = await this.repo.listProfiles(sourceId, user.isSuperuser ? undefined : user.id);
    const matchingProfile = profiles.find((profile) => buildPathMappingsHash(profile.pathMappings) === pathMappingsHash);
    if (!matchingProfile) return null;
    assertMigrationOwner(matchingProfile.createdByUserId, user);
    assertMigrationUserMappings(matchingProfile.userMappings, user);

    const scope = asRecord(matchingProfile.scope);
    const preflight = asRecord(scope.preflight);
    await this.repo.updateProfileScope(matchingProfile.id, {
      ...scope,
      preflight: {
        ...preflight,
        pathValidatedAt: validatedAt,
        pathMappingsHash,
      },
    });
    return matchingProfile.id;
  }

  private async assertNoGlobalActiveRun() {
    const runs = await this.repo.listRuns();
    const active = runs.find((row) => ACTIVE_LIVE_STATES.has(row.state));
    if (!active) return;
    throw new ConflictException(`Another migration run is active (runId=${active.id}, state=${active.state}).`);
  }
}

function scoreUserMapping(
  sourceUser: { username: string; email: string | null; name: string | null },
  targetUser: { username: string; email: string | null; name: string },
): number {
  const sUsername = sourceUser.username.trim().toLowerCase();
  const tUsername = targetUser.username.trim().toLowerCase();
  const sEmail = sourceUser.email?.trim().toLowerCase() ?? null;
  const tEmail = targetUser.email?.trim().toLowerCase() ?? null;
  const sName = sourceUser.name?.trim().toLowerCase() ?? null;
  const tName = targetUser.name.trim().toLowerCase();

  if (sEmail && tEmail && sEmail === tEmail) return 100;
  if (sUsername && tUsername && sUsername === tUsername) return 95;
  if (sName && tName && sName === tName) return 85;
  if (sUsername && tUsername && (sUsername.includes(tUsername) || tUsername.includes(sUsername))) return 70;
  if (sName && tName && (sName.includes(tName) || tName.includes(sName))) return 60;
  return 0;
}

function confidenceLabel(score: number): 'high' | 'medium' | 'low' {
  if (score >= 90) return 'high';
  if (score >= 70) return 'medium';
  return 'low';
}
