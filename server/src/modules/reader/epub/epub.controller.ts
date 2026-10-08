import { BadRequestException, Controller, Get, Param, ParseIntPipe, Query, Req, Res, ServiceUnavailableException } from '@nestjs/common';
import type { FastifyReply, FastifyRequest } from 'fastify';
import { Permission } from '@bookorbit/types';

import { CurrentUser } from '../../../common/decorators/current-user.decorator';
import { RequirePermission } from '../../../common/decorators/require-permission.decorator';
import type { RequestUser } from '../../../common/types/request-user';
import { EpubService } from './epub.service';
import { MediaOverlayClipsQueryDto } from './dto/media-overlay-clips-query.dto';

@Controller('epub')
export class EpubController {
  constructor(private readonly epubService: EpubService) {}

  @Get(':bookId/info')
  getBookInfo(@Param('bookId', ParseIntPipe) bookId: number, @Query('fileId') fileId: string | undefined, @CurrentUser() user: RequestUser) {
    return this.epubService.getBookInfo(bookId, this.parseFileId(fileId), user);
  }

  @Get(':bookId/media-overlay')
  @RequirePermission(Permission.LibraryDownload)
  getMediaOverlay(@Param('bookId', ParseIntPipe) bookId: number, @Query('fileId') fileId: string | undefined, @CurrentUser() user: RequestUser) {
    return this.epubService.getMediaOverlayPlaylist(bookId, this.parseFileId(fileId), user);
  }

  @Get(':bookId/media-overlay/clips')
  @RequirePermission(Permission.LibraryDownload)
  getMediaOverlayClips(@Param('bookId', ParseIntPipe) bookId: number, @Query() query: MediaOverlayClipsQueryDto, @CurrentUser() user: RequestUser) {
    return this.epubService.getMediaOverlayClips(bookId, query, user);
  }

  @Get(':bookId/media-overlay/file/*')
  @RequirePermission(Permission.LibraryDownload)
  async getMediaOverlayFile(
    @Param('bookId', ParseIntPipe) bookId: number,
    @Param('*') encodedPath: string,
    @Query('fileId') fileId: string | undefined,
    @CurrentUser() user: RequestUser,
    @Req() request: FastifyRequest,
    @Res() reply: FastifyReply,
    @Query('sectionIndex') sectionIndex?: string,
  ) {
    const filePath = this.decodePathParam(encodedPath);
    const range = typeof request.headers.range === 'string' ? request.headers.range : undefined;
    const parsedFileId = this.parseFileId(fileId);
    const cancellation = new AbortController();
    const cancel = () => cancellation.abort();
    reply.raw.once('close', cancel);
    let result;
    try {
      result = await this.epubService.streamMediaOverlayFile(
        bookId,
        filePath,
        parsedFileId,
        range,
        user,
        sectionIndex === undefined ? undefined : this.parseSectionIndex(sectionIndex),
        cancellation.signal,
      );
    } catch (error) {
      reply.raw.removeListener('close', cancel);
      if (error instanceof ServiceUnavailableException) reply.header('Retry-After', '1');
      throw error;
    }
    const { data, contentType, size, status, contentRange, contentLength, etag } = result;

    reply.code(status);
    reply.header('Content-Type', contentType);
    reply.header('Accept-Ranges', 'bytes');
    reply.header('Content-Length', contentLength ?? (Buffer.isBuffer(data) ? data.length : size));
    if (etag) reply.header('ETag', etag);
    if (contentRange) reply.header('Content-Range', contentRange);
    if (!contentRange && size > 0) reply.header('X-Content-Length-Full', size);
    reply.header('Cache-Control', 'private, max-age=3600');
    reply.send(data);
  }

  private parseSectionIndex(value: string): number {
    if (!/^\d+$/.test(value) || !Number.isSafeInteger(Number(value))) throw new BadRequestException('Invalid sectionIndex');
    return Number(value);
  }

  @Get(':bookId/file/*')
  async getFile(
    @Param('bookId', ParseIntPipe) bookId: number,
    @Param('*') encodedPath: string,
    @Query('fileId') fileId: string | undefined,
    @CurrentUser() user: RequestUser,
    @Res() reply: FastifyReply,
  ) {
    const filePath = this.decodePathParam(encodedPath);

    const { stream, contentType, size } = await this.epubService.streamFile(bookId, filePath, this.parseFileId(fileId), user);

    reply.header('Content-Type', contentType);
    if (size > 0) reply.header('Content-Length', size);
    reply.header('Cache-Control', 'public, max-age=3600');
    reply.send(stream);
  }

  private parseFileId(fileId: string | undefined): number | undefined {
    if (fileId === undefined) return undefined;
    const value = fileId.trim();
    if (!/^\d+$/.test(value)) {
      throw new BadRequestException('Invalid fileId');
    }

    const parsed = Number(value);
    if (!Number.isSafeInteger(parsed) || parsed <= 0) {
      throw new BadRequestException('Invalid fileId');
    }
    return parsed;
  }

  private decodePathParam(encodedPath: string): string {
    try {
      return encodedPath
        .split('/')
        .map((segment) => decodeURIComponent(segment))
        .join('/');
    } catch {
      throw new BadRequestException('Invalid file path');
    }
  }
}
