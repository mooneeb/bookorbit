import { Module } from '@nestjs/common';
import { HttpAdapterHost } from '@nestjs/core';
import type { FastifyInstance } from 'fastify';

import { BookModule } from '../book/book.module';
import { AchievementModule } from '../achievement/achievement.module';
import { PositionConverterModule } from '../position-converter/position-converter.module';
import { AnnotationController } from './annotation.controller';
import { AnnotationExportService } from './annotation-export.service';
import { AnnotationHubController } from './annotation-hub.controller';
import { AnnotationHubService } from './annotation-hub.service';
import { AnnotationHubMutationService } from './annotation-hub-mutation.service';
import { AnnotationConversionService } from './annotation-conversion.service';
import { AnnotationPositionRepository } from './annotation-position.repository';
import { AnnotationRepository } from './annotation.repository';
import { AnnotationService } from './annotation.service';
import { AnnotationSyncRepository } from './annotation-sync.repository';
import { AnnotationSyncService } from './annotation-sync.service';
import { DevicePositionRebuilderRegistry } from './device-position-rebuilder';
import { NativeAnnotationController } from './native-annotation.controller';
import { NativeAnnotationService, NATIVE_INK_PUBLISHER } from './native-annotation.service';
import { SourcePdfPublicationModule } from '../source-pdf-publication/source-pdf-publication.module';
import { SourcePdfPublicationService } from '../source-pdf-publication/source-pdf-publication.service';
import { NativeAnnotationHubService } from './native-annotation-hub.service';
import { NativeAnnotationHubController } from './native-annotation-hub.controller';
import { NativeSourceInkController } from './native-source-ink.controller';
import { NativeSourceInkService } from './native-source-ink.service';

@Module({
  imports: [BookModule, AchievementModule, PositionConverterModule, SourcePdfPublicationModule],
  controllers: [AnnotationController, AnnotationHubController, NativeAnnotationController, NativeAnnotationHubController, NativeSourceInkController],
  providers: [
    NativeAnnotationService,
    NativeAnnotationHubService,
    NativeSourceInkService,
    { provide: NATIVE_INK_PUBLISHER, useExisting: SourcePdfPublicationService },
    AnnotationService,
    AnnotationRepository,
    AnnotationPositionRepository,
    AnnotationSyncRepository,
    AnnotationSyncService,
    AnnotationConversionService,
    AnnotationExportService,
    AnnotationHubService,
    AnnotationHubMutationService,
    DevicePositionRebuilderRegistry,
  ],
  exports: [AnnotationSyncService, AnnotationHubService, AnnotationHubMutationService, DevicePositionRebuilderRegistry, NativeAnnotationService],
})
export class AnnotationModule {
  constructor(adapterHost: HttpAdapterHost) {
    const fastify = adapterHost.httpAdapter?.getInstance() as FastifyInstance | undefined;
    fastify?.addHook('onRoute', (route) => {
      if (
        route.url.endsWith('/annotations/native/operations') ||
        route.url.endsWith('/annotations/native/hub/bulk') ||
        route.url.endsWith('/annotations/native/source-ink/:bookId/:bookFileId/operations')
      ) {
        route.bodyLimit = 4 * 1024 * 1024;
      }
    });
  }
}
