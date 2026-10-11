import { Module } from '@nestjs/common';
import { KoboDownloadRepository } from './kobo-download.repository';
import { KoboSourcePublicationService } from './services/kobo-source-publication.service';

@Module({ providers: [KoboDownloadRepository, KoboSourcePublicationService], exports: [KoboSourcePublicationService] })
export class KoboSourcePublicationModule {}
