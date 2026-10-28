import { Module } from '@nestjs/common';

import { BookModule } from '../../book/book.module';
import { LibraryModule } from '../../library/library.module';
import { EpubController } from './epub.controller';
import { EpubService } from './epub.service';

import { EpubSessionService } from './epub-session.service';
import { EpubSessionController } from './epub-session.controller';

@Module({
  imports: [BookModule, LibraryModule],
  controllers: [EpubController, EpubSessionController],
  providers: [EpubService, EpubSessionService],
  exports: [EpubService],
})
export class EpubModule {}
