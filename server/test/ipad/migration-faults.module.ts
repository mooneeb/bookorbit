import { Body, Controller, ForbiddenException, Get, Global, HttpCode, Injectable, Module, Post } from '@nestjs/common';
import { IsIn, IsInt, IsOptional, Max, Min } from 'class-validator';
import { Permission } from '@bookorbit/types';
import { CurrentUser } from '../../src/common/decorators/current-user.decorator';
import { RequirePermission } from '../../src/common/decorators/require-permission.decorator';
import type { RequestUser } from '../../src/common/types/request-user';
import { MIGRATION_EXECUTION_CHECKPOINT, type MigrationExecutionCheckpoint } from '../../src/modules/migration/executor/migration-checkpoint';

class MigrationFaultDto {
  @IsIn(['delay', 'none'])
  mode!: 'delay' | 'none';

  @IsOptional()
  @IsIn(['shared_overlays', 'book_covers', 'user_state', 'completed'])
  stage?: 'shared_overlays' | 'book_covers' | 'user_state' | 'completed';

  @IsOptional()
  @IsInt()
  @Min(0)
  @Max(20_000)
  delayMs?: number;
}

@Injectable()
class MigrationFixtureCheckpoint {
  private armedDelayMs: number | null = null;
  private stage = 'user_state';
  private release: (() => void) | null = null;
  private observed: Parameters<MigrationExecutionCheckpoint>[0] | null = null;

  configure(dto: MigrationFaultDto) {
    this.release?.();
    this.armedDelayMs = dto.mode === 'delay' ? (dto.delayMs ?? 15_000) : null;
    this.observed = null;
    this.stage = dto.stage ?? 'user_state';
    return this.state();
  }

  state() {
    return { armed: this.armedDelayMs !== null, delayMs: this.armedDelayMs, stage: this.stage, observed: this.observed };
  }

  readonly checkpoint: MigrationExecutionCheckpoint = async (input) => {
    if (this.armedDelayMs === null || input.stage !== this.stage) return;
    const delayMs = this.armedDelayMs;
    this.armedDelayMs = null;
    this.observed = input;
    await new Promise<void>((resolve) => {
      const timer = setTimeout(() => {
        this.release = null;
        resolve();
      }, delayMs);
      this.release = () => {
        clearTimeout(timer);
        this.release = null;
        resolve();
      };
    });
  };
}

@Controller('__faults/migration')
@RequirePermission(Permission.ManageAppSettings)
class MigrationFaultController {
  constructor(private readonly boundary: MigrationFixtureCheckpoint) {}

  @Post()
  @HttpCode(200)
  configure(@CurrentUser() user: RequestUser, @Body() dto: MigrationFaultDto) {
    this.requireOwner(user);
    return this.boundary.configure(dto);
  }

  @Get()
  state(@CurrentUser() user: RequestUser) {
    this.requireOwner(user);
    return this.boundary.state();
  }

  private requireOwner(user: RequestUser) {
    if (!user.isSuperuser) throw new ForbiddenException('Migration fault controls require the isolated harness owner');
  }
}

@Global()
@Module({
  providers: [
    MigrationFixtureCheckpoint,
    {
      provide: MIGRATION_EXECUTION_CHECKPOINT,
      useFactory: (boundary: MigrationFixtureCheckpoint) => boundary.checkpoint,
      inject: [MigrationFixtureCheckpoint],
    },
  ],
  controllers: [MigrationFaultController],
  exports: [MIGRATION_EXECUTION_CHECKPOINT],
})
export class MigrationFaultsModule {}
