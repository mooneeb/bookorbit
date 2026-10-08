import { Body, Controller, Get, HttpCode, Param, ParseIntPipe, Post, Query, Res } from '@nestjs/common';
import type { FastifyReply } from 'fastify';
import { Permission } from '@bookorbit/types';

import { CurrentUser } from '../../common/decorators/current-user.decorator';
import { RequirePermission } from '../../common/decorators/require-permission.decorator';
import type { RequestUser } from '../../common/types/request-user';
import { NativeAnnotationHubService } from './native-annotation-hub.service';
import { NativeAnnotationOperationsDto } from './dto/native-annotation.dto';
import { NativeAnnotationHubDevicesQueryDto, NativeAnnotationHubExportQueryDto, NativeAnnotationHubQueryDto } from './dto/native-annotation-hub.dto';

@Controller('annotations/native/hub')
export class NativeAnnotationHubController {
  constructor(private readonly hub: NativeAnnotationHubService) {}

  @Get()
  list(@CurrentUser() user: RequestUser, @Query() query: NativeAnnotationHubQueryDto) {
    return this.hub.list(user.id, query);
  }

  @Get('export')
  @RequirePermission(Permission.AnnotationManageOwn)
  async export(@CurrentUser() user: RequestUser, @Query() query: NativeAnnotationHubExportQueryDto, @Res() reply: FastifyReply) {
    const result = await this.hub.export(user.id, query);
    return reply
      .header('Content-Type', result.contentType)
      .header('Content-Disposition', `attachment; filename="${result.filename}"`)
      .send(result.content);
  }

  @Get('drafts')
  @RequirePermission(Permission.AnnotationManageOwn)
  drafts(@CurrentUser() user: RequestUser, @Query() query: NativeAnnotationHubQueryDto) {
    return this.hub.drafts(user.id, query);
  }

  @Get('devices')
  @RequirePermission(Permission.AnnotationManageOwn)
  devices(@CurrentUser() user: RequestUser, @Query() query: NativeAnnotationHubDevicesQueryDto) {
    return this.hub.devices(user.id, query);
  }

  @Post('bulk')
  @HttpCode(200)
  @RequirePermission(Permission.AnnotationManageOwn)
  bulk(@CurrentUser() user: RequestUser, @Body() dto: NativeAnnotationOperationsDto) {
    return this.hub.bulk(user, dto);
  }

  @Post(':annotationId/repair')
  @HttpCode(200)
  @RequirePermission(Permission.AnnotationManageOwn)
  repair(@CurrentUser() user: RequestUser, @Param('annotationId', ParseIntPipe) annotationId: number, @Body() dto: NativeAnnotationOperationsDto) {
    return this.hub.repair(user, annotationId, dto);
  }
}
