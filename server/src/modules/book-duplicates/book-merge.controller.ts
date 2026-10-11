import { Body, Controller, HttpCode, HttpStatus, Post } from '@nestjs/common';
import { Permission } from '@bookorbit/types';
import { CurrentUser } from '../../common/decorators/current-user.decorator';
import { RequirePermission } from '../../common/decorators/require-permission.decorator';
import type { RequestUser } from '../../common/types/request-user';
import { BookMergeService } from './book-merge.service';
import { MergeBooksDto } from './dto/merge-books.dto';

@Controller('book-duplicates/merge')
@RequirePermission(Permission.LibraryDeleteBooks, Permission.LibraryEditMetadata)
export class BookMergeController {
  constructor(private readonly service: BookMergeService) {}

  @Post('preview')
  @HttpCode(HttpStatus.OK)
  preview(@Body() dto: MergeBooksDto, @CurrentUser() user: RequestUser) {
    return this.service.preview(dto, user);
  }

  @Post('apply')
  @HttpCode(HttpStatus.OK)
  apply(@Body() dto: MergeBooksDto, @CurrentUser() user: RequestUser) {
    return this.service.apply(dto, user);
  }
}
