import { Controller, Get, Param, ParseIntPipe, Res } from '@nestjs/common';
import type { FastifyReply } from 'fastify';
import { CurrentUser } from '../../../common/decorators/current-user.decorator';
import type { RequestUser } from '../../../common/types/request-user';
import { CbzService } from './cbz.service';
import { ComicPageCountResponseDto } from './dto/comic-page-count-response.dto';

@Controller('cbz')
export class CbzController {
  constructor(private readonly cbzService: CbzService) {}

  @Get('files/:fileId/pages')
  async getPageCount(@Param('fileId', ParseIntPipe) fileId: number, @CurrentUser() user: RequestUser): Promise<ComicPageCountResponseDto> {
    return { pageCount: await this.cbzService.getPageCount(fileId, user) };
  }

  @Get('files/:fileId/pages/:pageIndex')
  async getPage(
    @Param('fileId', ParseIntPipe) fileId: number,
    @Param('pageIndex', ParseIntPipe) pageIndex: number,
    @CurrentUser() user: RequestUser,
    @Res() reply: FastifyReply,
  ) {
    const { stream, mimeType } = await this.cbzService.streamPage(fileId, pageIndex, user);
    reply.header('Cache-Control', 'private, no-store');
    reply.type(mimeType);
    reply.send(stream);
  }
}
