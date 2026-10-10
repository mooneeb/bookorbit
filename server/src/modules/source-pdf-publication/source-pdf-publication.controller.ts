import { BadRequestException, Controller, Get, Param, ParseIntPipe, Query } from '@nestjs/common';

import { CurrentUser } from '../../common/decorators/current-user.decorator';
import type { RequestUser } from '../../common/types/request-user';
import { SourcePdfPublicationService } from './source-pdf-publication.service';
import { SourcePdfPageQueryDto } from './dto/source-pdf-page-query.dto';

@Controller('annotations/native/files')
export class SourcePdfPublicationController {
  constructor(private readonly service: SourcePdfPublicationService) {}

  @Get(':fileId/source')
  inspect(@Param('fileId', ParseIntPipe) fileId: number, @Query() query: SourcePdfPageQueryDto, @CurrentUser() user: RequestUser) {
    if ((query.page == null) === (query.pageStart == null)) throw new BadRequestException('Provide exactly one page or pageStart');
    if (query.page != null) return this.service.inspectPage(query.bookId, fileId, query.page, user, query.sourceRevision);
    return this.service.inspectPages(query.bookId, fileId, query.pageStart!, query.limit ?? 100, user, query.sourceRevision);
  }
}
