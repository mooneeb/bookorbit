import { Body, Controller, Get, Post, Query } from '@nestjs/common';
import { Permission } from '@bookorbit/types';
import { CurrentUser } from '../../common/decorators/current-user.decorator';
import { RequirePermission } from '../../common/decorators/require-permission.decorator';
import type { RequestUser } from '../../common/types/request-user';
import { NativeAnnotationService } from './native-annotation.service';
import { NativeAnnotationAckDto, NativeAnnotationDeltaQueryDto, NativeAnnotationOperationsDto } from './dto/native-annotation.dto';

@Controller('annotations/native')
export class NativeAnnotationController {
  constructor(private readonly service: NativeAnnotationService) {}
  @Get('delta')
  delta(@CurrentUser() user: RequestUser, @Query() query: NativeAnnotationDeltaQueryDto) {
    return this.service.delta(user, query);
  }
  @Post('operations')
  @RequirePermission(Permission.AnnotationManageOwn)
  operations(@CurrentUser() user: RequestUser, @Body() dto: NativeAnnotationOperationsDto) {
    return this.service.operations(user, dto);
  }
  @Post('ack')
  acknowledge(@CurrentUser() user: RequestUser, @Body() dto: NativeAnnotationAckDto) {
    return this.service.acknowledge(user, dto);
  }
}
