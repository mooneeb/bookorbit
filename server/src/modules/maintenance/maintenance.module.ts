import { Module } from '@nestjs/common';

import { BookModule } from '../book/book.module';
import { BookCoverStoreModule } from '../book-cover-store/book-cover-store.module';
import { ReadingAttemptEventsModule } from '../user-book-status/reading-attempt-events.module';
import { LibraryModule } from '../library/library.module';
import { CoverSweepStore } from './cover-sweep.store';
import { MissingResourcesController } from './missing-resources.controller';
import { MissingResourcesRepository } from './missing-resources.repository';
import { MissingResourcesService } from './missing-resources.service';
import { PathModule } from '../path/path.module';
import { MissingFileRepairService } from './missing-file-repair.service';

@Module({
  imports: [BookModule, BookCoverStoreModule, LibraryModule, ReadingAttemptEventsModule, PathModule],
  controllers: [MissingResourcesController],
  providers: [MissingResourcesService, MissingResourcesRepository, CoverSweepStore, MissingFileRepairService],
})
export class MaintenanceModule {}
