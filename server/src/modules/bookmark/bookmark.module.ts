import { Module } from '@nestjs/common';

import { BookModule } from '../book/book.module';
import { BookmarkController } from './bookmark.controller';
import { BookmarkRepository } from './bookmark.repository';
import { BookmarkService } from './bookmark.service';
import { BookmarkSyncService } from './bookmark-sync.service';
import { PositionConverterModule } from '../position-converter/position-converter.module';
import { EpubModule } from '../reader/epub/epub.module';
import { EpubBookmarkContextService } from './epub-bookmark-context.service';
import { EpubBookmarkNavigationService } from './epub-bookmark-navigation.service';

@Module({
  imports: [BookModule, EpubModule, PositionConverterModule],
  controllers: [BookmarkController],
  providers: [BookmarkService, BookmarkSyncService, BookmarkRepository, EpubBookmarkContextService, EpubBookmarkNavigationService],
  exports: [BookmarkSyncService],
})
export class BookmarkModule {}
