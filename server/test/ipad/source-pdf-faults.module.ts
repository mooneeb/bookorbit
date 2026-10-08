import { readFile, stat, unlink, writeFile } from 'node:fs/promises';
import { randomBytes } from 'node:crypto';
import {
  BadRequestException,
  Controller,
  ForbiddenException,
  Get,
  Global,
  HttpCode,
  Inject,
  Injectable,
  Module,
  Param,
  ParseIntPipe,
  Post,
  ServiceUnavailableException,
} from '@nestjs/common';
import { PDFDocument, PDFName } from 'pdf-lib';
import { Permission } from '@bookorbit/types';
import { and, eq } from 'drizzle-orm';
import type { NodePgDatabase } from 'drizzle-orm/node-postgres';
import { DB } from '../../src/db';
import * as schema from '../../src/db/schema';
import { computeFileHash } from '../../src/common/utils/file-hash.utils';
import { CurrentUser } from '../../src/common/decorators/current-user.decorator';
import { RequirePermission } from '../../src/common/decorators/require-permission.decorator';
import type { RequestUser } from '../../src/common/types/request-user';
import { BookModule } from '../../src/modules/book/book.module';
import { BookService } from '../../src/modules/book/book.service';
import {
  SOURCE_PDF_PUBLICATION_BOUNDARY,
  type SourcePdfPublicationBoundary,
} from '../../src/modules/source-pdf-publication/source-pdf-publication.service';

type PublicationPhase = 'prepared' | 'committed';

@Injectable()
class SourcePdfFixtureBoundary implements SourcePdfPublicationBoundary {
  private armed: PublicationPhase | undefined;
  private observed: PublicationPhase | undefined;

  arm(phase: string) {
    if (phase !== 'prepared' && phase !== 'committed') throw new BadRequestException('Unknown publication fault phase');
    this.armed = phase;
    this.observed = undefined;
  }

  state() {
    return { armed: this.armed ?? null, observed: this.observed ?? null };
  }

  reset() {
    this.armed = undefined;
    this.observed = undefined;
  }

  onPhase(input: Parameters<SourcePdfPublicationBoundary['onPhase']>[0]): Promise<void> {
    if (input.phase !== this.armed) return Promise.resolve();
    this.observed = input.phase;
    this.armed = undefined;
    return Promise.reject(new ServiceUnavailableException(`Controlled source PDF interruption at ${input.phase}`));
  }
}

@Controller('__faults/source-pdf')
class SourcePdfFixtureController {
  private original: Uint8Array | undefined;

  constructor(
    private readonly boundary: SourcePdfFixtureBoundary,
    private readonly books: BookService,
    @Inject(DB) private readonly db: NodePgDatabase<typeof schema>,
  ) {}

  @Post('arm/:phase')
  @HttpCode(204)
  arm(@Param('phase') phase: string) {
    this.boundary.arm(phase);
  }

  @Get('state')
  state() {
    return this.boundary.state();
  }

  @Post('reset')
  @HttpCode(204)
  reset() {
    this.boundary.reset();
  }

  @Post('source/:fileId/:mode')
  @RequirePermission(Permission.LibraryEditMetadata)
  @HttpCode(204)
  async changeSource(@Param('fileId', ParseIntPipe) fileId: number, @Param('mode') mode: string, @CurrentUser() user: RequestUser) {
    if (!user.isSuperuser) throw new ForbiddenException('Source fault fixtures require the isolated harness owner');
    if (fileId !== 1 || !['snapshot', 'replace', 'delete', 'restore', 'protect', 'large'].includes(mode))
      throw new BadRequestException('Unsupported source fixture');
    const file = await this.books.verifyFileAccess(fileId, user);
    if (mode === 'snapshot') {
      this.original = await readFile(file.absolutePath);
      return;
    }
    if (!this.original) this.original = await readFile(file.absolutePath);
    if (mode === 'delete') {
      await unlink(file.absolutePath);
    } else if (mode === 'restore') {
      await writeFile(file.absolutePath, this.original);
      const state = await stat(file.absolutePath, { bigint: true });
      await this.db
        .update(schema.bookFiles)
        .set({
          fileHash: await computeFileHash(file.absolutePath),
          mtime: state.mtime,
          sizeBytes: Number(state.size),
          ino: state.ino,
          updatedAt: new Date(),
        })
        .where(and(eq(schema.bookFiles.id, fileId), eq(schema.bookFiles.bookId, file.bookId)));
      this.original = undefined;
    } else if (mode === 'replace') {
      const replacement = await PDFDocument.create();
      replacement.addPage([420, 600]).drawText('Replacement source fixture', { x: 40, y: 500 });
      await writeFile(file.absolutePath, await replacement.save());
    } else if (mode === 'large') {
      const largeSource = await PDFDocument.create();
      const page = largeSource.addPage([600, 800]);
      page.drawText('Large source fixture', { x: 50, y: 700 });
      const content = largeSource.context.register(largeSource.context.stream(`%${randomBytes(12 * 1024 * 1024).toString('hex')}\n`));
      page.node.addContentStream(content);
      await writeFile(file.absolutePath, await largeSource.save());
    } else {
      const protectedSource = await PDFDocument.load(await readFile(file.absolutePath));
      protectedSource.catalog.set(PDFName.of('Perms'), protectedSource.context.obj({ FixtureProtected: true }));
      await writeFile(file.absolutePath, await protectedSource.save());
    }
  }
}

@Global()
@Module({
  imports: [BookModule],
  providers: [SourcePdfFixtureBoundary, { provide: SOURCE_PDF_PUBLICATION_BOUNDARY, useExisting: SourcePdfFixtureBoundary }],
  controllers: [SourcePdfFixtureController],
  exports: [SOURCE_PDF_PUBLICATION_BOUNDARY],
})
export class SourcePdfFaultsModule {}
