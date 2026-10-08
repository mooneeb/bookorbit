import { Body, Controller, Delete, Get, HttpCode, Param, ParseIntPipe, Post, Query, Res } from '@nestjs/common';
import type { FastifyReply } from 'fastify';
import { Permission } from '@bookorbit/types';

import { CurrentUser } from '../../common/decorators/current-user.decorator';
import { RequirePermission } from '../../common/decorators/require-permission.decorator';
import type { RequestUser } from '../../common/types/request-user';
import { AnnotationHubService } from './annotation-hub.service';
import { AnnotationHubMutationService } from './annotation-hub-mutation.service';
import {
  AnnotationBulkDto,
  AnnotationExportQueryDto,
  AnnotationHubBooksQueryDto,
  AnnotationHubQueryDto,
  AnnotationPositionRetryDto,
} from './dto/annotation-hub.dto';

@Controller('annotations')
export class AnnotationHubController {
  constructor(
    private readonly hubService: AnnotationHubService,
    private readonly mutations: AnnotationHubMutationService,
  ) {}

  @Get()
  list(@CurrentUser() user: RequestUser, @Query() query: AnnotationHubQueryDto) {
    return this.hubService.list(user.id, query);
  }

  @Get('overview')
  overview(@CurrentUser() user: RequestUser, @Query() query: AnnotationHubQueryDto) {
    return this.hubService.overview(user.id, query);
  }

  @Get('books')
  listBooks(@CurrentUser() user: RequestUser, @Query() query: AnnotationHubBooksQueryDto) {
    return this.hubService.listBooks(user.id, {
      status: query.status ?? 'active',
      q: query.q,
      limit: query.limit,
      selectedId: query.selectedId,
    });
  }

  @Post('bulk')
  @RequirePermission(Permission.AnnotationManageOwn)
  @HttpCode(200)
  bulk(@CurrentUser() user: RequestUser, @Body() dto: AnnotationBulkDto) {
    return this.mutations.bulk(user, dto);
  }

  @Post(':annotationId/restore')
  @RequirePermission(Permission.AnnotationManageOwn)
  @HttpCode(200)
  restore(@CurrentUser() user: RequestUser, @Param('annotationId', ParseIntPipe) annotationId: number) {
    return this.mutations.restore(user, annotationId);
  }

  @Get(':annotationId/sync-detail')
  syncDetail(@CurrentUser() user: RequestUser, @Param('annotationId', ParseIntPipe) annotationId: number) {
    return this.hubService.syncDetail(user.id, annotationId);
  }

  @Post(':annotationId/positions/retry')
  @RequirePermission(Permission.AnnotationManageOwn)
  @HttpCode(200)
  retryPosition(
    @CurrentUser() user: RequestUser,
    @Param('annotationId', ParseIntPipe) annotationId: number,
    @Body() dto: AnnotationPositionRetryDto,
  ) {
    return this.mutations.retryPosition(user, annotationId, dto.format);
  }

  @Delete(':annotationId')
  @RequirePermission(Permission.AnnotationManageOwn)
  @HttpCode(204)
  async purge(@CurrentUser() user: RequestUser, @Param('annotationId', ParseIntPipe) annotationId: number) {
    await this.hubService.purge(user.id, annotationId);
  }

  @Get('export')
  async export(@CurrentUser() user: RequestUser, @Query() query: AnnotationExportQueryDto, @Res() reply: FastifyReply) {
    const result = await this.hubService.export(user.id, query, query.bookId ? `book-${query.bookId}` : 'library');
    return reply
      .header('Content-Type', result.contentType)
      .header('Content-Disposition', `attachment; filename="${result.filename}"`)
      .send(result.content);
  }
}
