import { Module } from '@nestjs/common';

import { BookCoverStoreModule } from '../book-cover-store/book-cover-store.module';
import { BookModule } from '../book/book.module';
import { LibraryModule } from '../library/library.module';
import { BookDuplicatesController } from './book-duplicates.controller';
import { BookDuplicatesRepository } from './book-duplicates.repository';
import { BookDuplicatesService } from './book-duplicates.service';
import { BookMergeCoverService } from './book-merge-cover.service';
import { BookMergeController } from './book-merge.controller';
import { BookMergeRepository } from './book-merge.repository';
import { BookMergeService } from './book-merge.service';

@Module({
  imports: [LibraryModule, BookModule, BookCoverStoreModule],
  controllers: [BookDuplicatesController, BookMergeController],
  providers: [BookDuplicatesService, BookDuplicatesRepository, BookMergeService, BookMergeRepository, BookMergeCoverService],
})
export class BookDuplicatesModule {}
