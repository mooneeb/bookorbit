import { Module } from '@nestjs/common';
import { BookMergeScanRepository } from './book-merge-scan.repository';
import { BookMergeScanService } from './book-merge-scan.service';

@Module({ providers: [BookMergeScanRepository, BookMergeScanService], exports: [BookMergeScanService] })
export class BookMergeScanModule {}
