import { BadRequestException, Body, Controller, Delete, Get, HttpCode, Param, ParseIntPipe, Post, Query, Res } from '@nestjs/common';
import type { FastifyReply } from 'fastify';
import { randomUUID } from 'node:crypto';
import { Permission, type NativeAnnotationItem } from '@bookorbit/types';

import { CurrentUser } from '../../common/decorators/current-user.decorator';
import { RequirePermission } from '../../common/decorators/require-permission.decorator';
import type { RequestUser } from '../../common/types/request-user';
import { AnnotationHubService } from './annotation-hub.service';
import { NativeAnnotationService } from './native-annotation.service';
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
    private readonly nativeAnnotations: NativeAnnotationService,
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
  async bulk(@CurrentUser() user: RequestUser, @Body() dto: AnnotationBulkDto) {
    const versioned: NativeAnnotationItem[] = [];
    for (let offset = 0; offset < dto.ids.length; offset += 100) {
      versioned.push(
        ...(await this.nativeAnnotations.getItems(dto.ids.slice(offset, offset + 100), user.id)).filter((item) => item.clientId != null),
      );
    }
    if (versioned.length && (dto.action === 'trash' || dto.action === 'restore')) {
      const result = await this.nativeAnnotations.operations(user, {
        deviceId: 'web-annotation-hub',
        operations: versioned.map((item) => ({
          operationId: randomUUID(),
          clientId: item.clientId!,
          annotationId: item.id,
          bookId: item.bookId,
          baseVersion: item.version,
          action: dto.action === 'trash' ? 'delete' : 'restore',
        })),
      });
      const versionedIds = new Set(versioned.map((item) => item.id));
      const legacy = await this.hubService.bulk(user.id, { ...dto, ids: dto.ids.filter((id) => !versionedIds.has(id)) });
      return { affected: legacy.affected + result.results.filter((item) => item.status === 'applied').length };
    }
    return this.hubService.bulk(user.id, dto);
  }

  @Post(':annotationId/restore')
  @RequirePermission(Permission.AnnotationManageOwn)
  @HttpCode(200)
  async restore(@CurrentUser() user: RequestUser, @Param('annotationId', ParseIntPipe) annotationId: number) {
    const item = await this.nativeAnnotations.getItem(annotationId, user.id);
    if (item?.clientId) {
      const result = await this.nativeAnnotations.operations(user, {
        deviceId: 'web-annotation-hub',
        operations: [
          { operationId: randomUUID(), clientId: item.clientId, annotationId, bookId: item.bookId, baseVersion: item.version, action: 'restore' },
        ],
      });
      return result.results[0]?.annotation;
    }
    return this.hubService.restore(user.id, annotationId);
  }

  @Get(':annotationId/sync-detail')
  syncDetail(@CurrentUser() user: RequestUser, @Param('annotationId', ParseIntPipe) annotationId: number) {
    return this.hubService.syncDetail(user.id, annotationId);
  }

  @Post(':annotationId/positions/retry')
  @RequirePermission(Permission.AnnotationManageOwn)
  @HttpCode(200)
  async retryPosition(
    @CurrentUser() user: RequestUser,
    @Param('annotationId', ParseIntPipe) annotationId: number,
    @Body() dto: AnnotationPositionRetryDto,
  ) {
    const item = await this.nativeAnnotations.getItem(annotationId, user.id);
    if (item?.kind === 'pdf_ink') throw new BadRequestException('Source PDF ink must use versioned anchor repair');
    return this.hubService.retryPosition(user.id, annotationId, dto.format);
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
