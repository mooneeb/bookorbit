import { Body, Controller, Delete, Get, HttpCode, HttpStatus, Param, ParseIntPipe, Post, Query, Res, UseGuards } from '@nestjs/common';
import type { FastifyReply } from 'fastify';
import { Permission } from '@bookorbit/types';

import { CurrentUser } from '../../common/decorators/current-user.decorator';
import { RequirePermission } from '../../common/decorators/require-permission.decorator';
import type { RequestUser } from '../../common/types/request-user';
import { CreateDryRunPlanDto } from './dto/create-dry-run-plan.dto';
import { CreateMigrationProfileDto } from './dto/create-migration-profile.dto';
import { CreateMigrationSourceDto } from './dto/create-migration-source.dto';
import { ResolveDuplicateMatchesDto } from './dto/resolve-duplicate-matches.dto';
import { StartLiveRunDto } from './dto/start-live-run.dto';
import { TestMigrationSourceDto } from './dto/test-migration-source.dto';
import { ValidatePathMappingsDto } from './dto/validate-path-mappings.dto';
import { MigrationSourceService } from './migration-source.service';
import { MigrationProfileService } from './migration-profile.service';
import { MigrationService } from './migration.service';
import { MigrationAccessGuard } from './migration-access.guard';
import { MigrationPlanPageDto } from './dto/migration-plan-page.dto';
import { MigrationOffsetPageDto, MigrationReportPageDto } from './dto/migration-report-page.dto';

@Controller('migration')
@UseGuards(MigrationAccessGuard)
@RequirePermission(Permission.ManageAppSettings)
export class MigrationController {
  constructor(
    private readonly sourceService: MigrationSourceService,
    private readonly profileService: MigrationProfileService,
    private readonly runService: MigrationService,
  ) {}

  @Get('supported-types')
  listSupportedTypes() {
    return this.sourceService.listSupportedSourceTypes();
  }

  @Post('sources/test')
  testSource(@Body() dto: TestMigrationSourceDto) {
    return this.sourceService.testSource(dto);
  }

  @Get('state')
  getWorkflowState(@CurrentUser() user: RequestUser) {
    return this.runService.getWorkflowState(user);
  }

  @Get('target-users')
  listTargetUsers(@CurrentUser() user: RequestUser) {
    return this.profileService.listTargetUsers(user);
  }

  @Post('sources')
  createSource(@Body() dto: CreateMigrationSourceDto, @CurrentUser() user: RequestUser) {
    return this.sourceService.createSource(dto, user);
  }

  @Post('sources/:id/validate')
  @HttpCode(HttpStatus.OK)
  validateSourceById(@Param('id', ParseIntPipe) sourceId: number, @CurrentUser() user: RequestUser) {
    return this.sourceService.validateSourceById(sourceId, user);
  }

  @Delete('sources/:id')
  @HttpCode(HttpStatus.NO_CONTENT)
  resetSource(@Param('id', ParseIntPipe) sourceId: number, @CurrentUser() user: RequestUser) {
    return this.sourceService.resetSource(sourceId, user);
  }

  @Get('sources/:id/path-prefixes')
  getSourcePathPrefixes(@Param('id', ParseIntPipe) sourceId: number, @CurrentUser() user: RequestUser) {
    return this.sourceService.getSourcePathPrefixes(sourceId, user);
  }

  @Get('sources/:id/user-mapping-suggestions')
  suggestUserMappings(@Param('id', ParseIntPipe) sourceId: number, @CurrentUser() user: RequestUser) {
    return this.profileService.suggestUserMappings(sourceId, user);
  }

  @Post('sources/:id/path-mappings/validate')
  validatePathMappings(@Param('id', ParseIntPipe) sourceId: number, @Body() dto: ValidatePathMappingsDto, @CurrentUser() user: RequestUser) {
    return this.profileService.validatePathMappings(sourceId, dto, user);
  }

  @Post('profiles')
  createProfile(@Body() dto: CreateMigrationProfileDto, @CurrentUser() user: RequestUser) {
    return this.profileService.createProfile(dto, user);
  }

  @Post('plans/dry-run')
  createDryRunPlan(@Body() dto: CreateDryRunPlanDto, @CurrentUser() user: RequestUser) {
    return this.runService.createDryRunPlan(dto, user);
  }

  @Get('plans/:id/matches')
  getPlanMatches(@Param('id', ParseIntPipe) artifactId: number, @Query() query: MigrationPlanPageDto, @CurrentUser() user: RequestUser) {
    return this.runService.getPlanMatches(artifactId, query.kind, query.offset, query.limit, user);
  }

  @Get('plans/:id/duplicates/:targetBookId/candidates')
  getDuplicateCandidates(
    @Param('id', ParseIntPipe) artifactId: number,
    @Param('targetBookId', ParseIntPipe) targetBookId: number,
    @Query() query: MigrationOffsetPageDto,
    @CurrentUser() user: RequestUser,
  ) {
    return this.runService.getDuplicateCandidates(artifactId, targetBookId, query.offset, query.limit, user);
  }

  @Post('plans/:id/resolve-duplicates')
  @HttpCode(HttpStatus.OK)
  resolveDuplicateMatches(@Param('id', ParseIntPipe) artifactId: number, @Body() dto: ResolveDuplicateMatchesDto, @CurrentUser() user: RequestUser) {
    return this.runService.resolveDuplicateMatches(artifactId, dto, user);
  }

  @Post('runs/live')
  startLiveRun(@Body() dto: StartLiveRunDto, @CurrentUser() user: RequestUser) {
    return this.runService.startLiveRun(dto, user);
  }

  @Post('runs/:id/cancel')
  @HttpCode(HttpStatus.OK)
  cancelRun(@Param('id', ParseIntPipe) runId: number, @CurrentUser() user: RequestUser) {
    return this.runService.cancelRun(runId, user);
  }

  @Post('runs/:id/retry')
  @HttpCode(HttpStatus.OK)
  retryRun(@Param('id', ParseIntPipe) runId: number, @CurrentUser() user: RequestUser) {
    return this.runService.retryFailedRun(runId, user);
  }

  @Get('runs/:id/progress')
  getRunProgress(@Param('id', ParseIntPipe) runId: number, @CurrentUser() user: RequestUser) {
    return this.runService.getRunProgress(runId, user);
  }

  @Get('runs/:id/report')
  getRunReport(@Param('id', ParseIntPipe) runId: number, @CurrentUser() user: RequestUser) {
    return this.runService.getRunReport(runId, user);
  }

  @Get('runs/:id/report/details')
  getRunDetails(@Param('id', ParseIntPipe) runId: number, @Query() query: MigrationReportPageDto, @CurrentUser() user: RequestUser) {
    return this.runService.getRunDetails(runId, query.kind, query.offset, query.limit, user);
  }

  @Get('runs/:id/report/export')
  async exportRunReport(
    @Param('id', ParseIntPipe) runId: number,
    @Query('format') format: string | undefined,
    @Res() reply: FastifyReply,
    @CurrentUser() user: RequestUser,
  ) {
    const result = await this.runService.exportRunReport(runId, format, user);
    return reply
      .header('Content-Type', result.contentType)
      .header('Content-Disposition', `attachment; filename="${result.fileName}"`)
      .send(result.content);
  }
}
