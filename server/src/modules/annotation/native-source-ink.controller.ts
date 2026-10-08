import { Body, Controller, Get, Param, Post, Query } from '@nestjs/common';
import { Permission } from '@bookorbit/types';
import { CurrentUser } from '../../common/decorators/current-user.decorator';
import { RequirePermission } from '../../common/decorators/require-permission.decorator';
import type { RequestUser } from '../../common/types/request-user';
import { NativeAnnotationOperationsDto } from './dto/native-annotation.dto';
import { NativeSourceInkQueryDto, NativeSourceInkScopeDto } from './dto/native-source-ink.dto';
import { NativeSourceInkService } from './native-source-ink.service';

@Controller('annotations/native/source-ink')
export class NativeSourceInkController {
  constructor(private readonly service: NativeSourceInkService) {}

  @Get()
  delta(@CurrentUser() user: RequestUser, @Query() query: NativeSourceInkQueryDto) {
    return this.service.delta(user, query);
  }

  @Post(':bookId/:bookFileId/operations')
  @RequirePermission(Permission.LibraryEditMetadata)
  operations(@CurrentUser() user: RequestUser, @Param() scope: NativeSourceInkScopeDto, @Body() dto: NativeAnnotationOperationsDto) {
    return this.service.operations(user, scope, dto);
  }
}
