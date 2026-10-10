import { Module } from '@nestjs/common';

import { SelfWriteRegistryModule } from '../../common/self-write-registry.module';
import { BookModule } from '../book/book.module';
import { FileWriteModule } from '../file-write/file-write.module';
import { SourcePdfPublicationRepository } from './source-pdf-publication.repository';
import { SourcePdfPublicationService } from './source-pdf-publication.service';
import { SourcePdfPublicationController } from './source-pdf-publication.controller';

@Module({
  imports: [BookModule, FileWriteModule, SelfWriteRegistryModule],
  providers: [SourcePdfPublicationRepository, SourcePdfPublicationService],
  controllers: [SourcePdfPublicationController],
  exports: [SourcePdfPublicationService],
})
export class SourcePdfPublicationModule {}
