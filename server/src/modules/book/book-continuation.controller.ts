import { Controller, Get, Header, Param, ParseIntPipe, Query } from '@nestjs/common';
import { Permission, type BookContinuationResponse } from '@bookorbit/types';
import { CurrentUser } from '../../common/decorators/current-user.decorator';
import { RequirePermission } from '../../common/decorators/require-permission.decorator';
import type { RequestUser } from '../../common/types/request-user';
import { BookContinuationService } from './book-continuation.service';
import { BookContinuationQueryDto } from './dto/book-continuation-query.dto';

@Controller('books/:bookId/continuation')
@RequirePermission(Permission.LibraryDownload)
export class BookContinuationController {
  constructor(private readonly service: BookContinuationService) {}

  @Get()
  @Header('Cache-Control', 'private, no-store')
  resolve(
    @Param('bookId', ParseIntPipe) bookId: number,
    @Query() query: BookContinuationQueryDto,
    @CurrentUser() user: RequestUser,
  ): Promise<BookContinuationResponse> {
    return this.service.resolve(bookId, query, user);
  }
}
