import {
  Body,
  Controller,
  Delete,
  Get,
  Headers,
  HttpCode,
  HttpStatus,
  Param,
  ParseIntPipe,
  ParseUUIDPipe,
  Patch,
  Post,
  Put,
  Query,
  Res,
} from '@nestjs/common';
import { basename } from 'node:path';

import type { FastifyReply } from 'fastify';
import { Permission } from '@bookorbit/types';

import { CurrentUser } from '../../common/decorators/current-user.decorator';
import { RequirePermission } from '../../common/decorators/require-permission.decorator';
import type { RequestUser } from '../../common/types/request-user';
import { contentDispositionHeader } from '../../common/utils/content-disposition.utils';
import { AudiobookService } from './audiobook.service';
import { serveVerifiedFile } from '../../common/utils/file-delivery.utils';
import { AudiobookBookmarksPageQueryDto } from './dto/audiobook-bookmarks-page-query.dto';
import { CreateAudiobookBookmarkDto } from './dto/create-audiobook-bookmark.dto';
import { DeletePlaybackStateQueryDto } from './dto/delete-playback-state-query.dto';
import { PutAudiobookPlaybackStateDto } from './dto/put-audiobook-playback-state.dto';
import { UpdateAudiobookBookmarkDto } from './dto/update-audiobook-bookmark.dto';

const AUDIO_MIME_TYPES: Record<string, string> = {
  m4b: 'audio/mp4',
  m4a: 'audio/mp4',
  mp3: 'audio/mpeg',
  opus: 'audio/ogg; codecs=opus',
  ogg: 'audio/ogg',
  flac: 'audio/flac',
};

@Controller('audiobooks')
@RequirePermission(Permission.LibraryDownload)
export class AudiobookController {
  constructor(private readonly service: AudiobookService) {}

  @Get(':bookId/manifest')
  getManifest(@Param('bookId', ParseIntPipe) bookId: number, @CurrentUser() user: RequestUser) {
    return this.service.getManifest(bookId, user);
  }

  @Get(':bookId/assets/:assetId/content')
  async serveAsset(
    @Param('bookId', ParseIntPipe) bookId: number,
    @Param('assetId') assetId: string,
    @CurrentUser() user: RequestUser,
    @Headers('range') rangeHeader: string | undefined,
    @Res() reply: FastifyReply,
    @Headers('if-range') ifRangeHeader?: string,
  ) {
    const asset = await this.service.getAsset(bookId, assetId, user);
    const mimeType = AUDIO_MIME_TYPES[asset.format.toLowerCase()] ?? 'application/octet-stream';
    reply.header('Content-Disposition', contentDispositionHeader('inline', basename(asset.absolutePath), 'audiobook'));
    reply.type(mimeType);
    await serveVerifiedFile(reply, asset.absolutePath, rangeHeader, ifRangeHeader, { userId: user.id, resourceId: assetId });
  }

  @Get(':bookId/playback-state')
  getPlaybackState(@Param('bookId', ParseIntPipe) bookId: number, @CurrentUser() user: RequestUser) {
    return this.service.getPlaybackState(bookId, user);
  }

  @Put(':bookId/playback-state')
  putPlaybackState(@Param('bookId', ParseIntPipe) bookId: number, @Body() dto: PutAudiobookPlaybackStateDto, @CurrentUser() user: RequestUser) {
    return this.service.putPlaybackState(bookId, dto, user);
  }

  @Delete(':bookId/playback-state')
  @HttpCode(HttpStatus.NO_CONTENT)
  deletePlaybackState(
    @Param('bookId', ParseIntPipe) bookId: number,
    @CurrentUser() user: RequestUser,
    @Query() query: DeletePlaybackStateQueryDto = {},
  ) {
    return query.baseRevision !== undefined ? this.service.deletePlaybackState(bookId, user, query) : this.service.deletePlaybackState(bookId, user);
  }

  @Get(':bookId/bookmarks')
  listBookmarks(@Param('bookId', ParseIntPipe) bookId: number, @CurrentUser() user: RequestUser) {
    return this.service.listBookmarks(bookId, user);
  }

  @Get(':bookId/bookmarks/page')
  listBookmarksPage(@Param('bookId', ParseIntPipe) bookId: number, @Query() query: AudiobookBookmarksPageQueryDto, @CurrentUser() user: RequestUser) {
    return this.service.listBookmarksPage(bookId, query, user);
  }

  @Post(':bookId/bookmarks')
  @RequirePermission(Permission.LibraryDownload, Permission.AnnotationManageOwn)
  createBookmark(@Param('bookId', ParseIntPipe) bookId: number, @Body() dto: CreateAudiobookBookmarkDto, @CurrentUser() user: RequestUser) {
    return this.service.createBookmark(bookId, dto, user);
  }

  @Patch(':bookId/bookmarks/:bookmarkId')
  @RequirePermission(Permission.LibraryDownload, Permission.AnnotationManageOwn)
  updateBookmark(
    @Param('bookId', ParseIntPipe) bookId: number,
    @Param('bookmarkId', ParseUUIDPipe) bookmarkId: string,
    @Body() dto: UpdateAudiobookBookmarkDto,
    @CurrentUser() user: RequestUser,
  ) {
    return this.service.updateBookmark(bookId, bookmarkId, dto, user);
  }

  @Delete(':bookId/bookmarks/:bookmarkId')
  @RequirePermission(Permission.LibraryDownload, Permission.AnnotationManageOwn)
  @HttpCode(HttpStatus.NO_CONTENT)
  deleteBookmark(
    @Param('bookId', ParseIntPipe) bookId: number,
    @Param('bookmarkId', ParseUUIDPipe) bookmarkId: string,
    @CurrentUser() user: RequestUser,
  ) {
    return this.service.deleteBookmark(bookId, bookmarkId, user);
  }
}
