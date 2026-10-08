import { Body, Controller, Delete, Get, HttpCode, HttpStatus, Param, ParseIntPipe, Post, Query } from '@nestjs/common';
import { Permission } from '@bookorbit/types';

import { CurrentUser } from '../../common/decorators/current-user.decorator';
import { RequirePermission } from '../../common/decorators/require-permission.decorator';
import type { RequestUser } from '../../common/types/request-user';
import { BookmarkService } from './bookmark.service';
import { CreateBookmarkDto } from './dto/create-bookmark.dto';
import { BookmarkPageDto } from './dto/bookmark-page.dto';
import { EpubBookmarkPageDto } from './dto/epub-bookmark-page.dto';
import { CreateFixedPageBookmarkDto } from './dto/create-fixed-page-bookmark.dto';
import { EpubBookmarkNavigationDto } from './dto/epub-bookmark-navigation.dto';
import { EpubBookmarkNavigationService } from './epub-bookmark-navigation.service';

@Controller('books/:bookId/bookmarks')
export class BookmarkController {
  constructor(
    private readonly bookmarkService: BookmarkService,
    private readonly navigation: EpubBookmarkNavigationService,
  ) {}

  @Get()
  getBookmarks(@Param('bookId', ParseIntPipe) bookId: number, @CurrentUser() user: RequestUser) {
    return this.bookmarkService.getBookmarks(bookId, user);
  }

  @Post()
  @RequirePermission(Permission.LibraryDownload)
  createBookmark(@Param('bookId', ParseIntPipe) bookId: number, @Body() dto: CreateBookmarkDto, @CurrentUser() user: RequestUser) {
    return this.bookmarkService.createBookmark(bookId, user, dto);
  }

  @Get('page')
  @RequirePermission(Permission.LibraryDownload)
  getPage(@Param('bookId', ParseIntPipe) bookId: number, @Query() dto: BookmarkPageDto, @CurrentUser() user: RequestUser) {
    return this.bookmarkService.getPage(bookId, user, dto);
  }

  @Get('epub-page')
  @RequirePermission(Permission.LibraryDownload)
  getEpubPage(@Param('bookId', ParseIntPipe) bookId: number, @Query() dto: EpubBookmarkPageDto, @CurrentUser() user: RequestUser) {
    return this.bookmarkService.getEpubPage(bookId, user, dto);
  }

  @Get('epub-navigation')
  @RequirePermission(Permission.LibraryDownload)
  getEpubNavigation(@Param('bookId', ParseIntPipe) bookId: number, @Query() dto: EpubBookmarkNavigationDto, @CurrentUser() user: RequestUser) {
    return this.navigation.page(bookId, user, dto);
  }

  @Post('fixed-page')
  @RequirePermission(Permission.LibraryDownload)
  createFixedPageBookmark(@Param('bookId', ParseIntPipe) bookId: number, @Body() dto: CreateFixedPageBookmarkDto, @CurrentUser() user: RequestUser) {
    return this.bookmarkService.createFixedPageBookmark(bookId, user, dto);
  }

  @Delete(':bookmarkId')
  @RequirePermission(Permission.LibraryDownload)
  @HttpCode(HttpStatus.NO_CONTENT)
  async deleteBookmark(
    @Param('bookId', ParseIntPipe) bookId: number,
    @Param('bookmarkId', ParseIntPipe) bookmarkId: number,
    @CurrentUser() user: RequestUser,
  ) {
    await this.bookmarkService.deleteBookmark(bookId, bookmarkId, user);
  }
}
