import { Module } from '@nestjs/common';

import { AchievementModule } from '../achievement/achievement.module';
import { BookModule } from '../book/book.module';
import { LibraryModule } from '../library/library.module';
import { UserBookStatusModule } from '../user-book-status/user-book-status.module';
import { UserModule } from '../user/user.module';
import { HardcoverAutoSyncSchedulerService } from './hardcover-auto-sync-scheduler.service';
import { HardcoverBookMatchService } from './hardcover-book-match.service';
import { HardcoverClientService } from './hardcover-client.service';
import { HardcoverController } from './hardcover.controller';
import { HardcoverEventListener } from './hardcover-event-listener.service';
import { HardcoverImportService } from './hardcover-import.service';
import { HardcoverImportRepository } from './hardcover-import.repository';
import { HardcoverQueueService } from './hardcover-queue.service';
import { HardcoverRepository } from './hardcover.repository';
import { HardcoverSettingsService } from './hardcover-settings.service';
import { HardcoverSyncService } from './hardcover-sync.service';

@Module({
  imports: [AchievementModule, BookModule, LibraryModule, UserBookStatusModule, UserModule],
  controllers: [HardcoverController],
  providers: [
    HardcoverQueueService,
    HardcoverClientService,
    HardcoverRepository,
    HardcoverSettingsService,
    HardcoverBookMatchService,
    HardcoverSyncService,
    HardcoverImportService,
    HardcoverImportRepository,
    HardcoverAutoSyncSchedulerService,
    HardcoverEventListener,
  ],
  exports: [HardcoverSyncService, HardcoverSettingsService],
})
export class HardcoverModule {}
