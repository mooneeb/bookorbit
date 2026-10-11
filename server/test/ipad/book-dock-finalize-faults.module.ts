import {
  BadRequestException,
  Controller,
  ForbiddenException,
  Global,
  HttpCode,
  Injectable,
  Module,
  Param,
  Post,
  ServiceUnavailableException,
} from '@nestjs/common';
import { randomUUID } from 'crypto';
import { mkdir, writeFile } from 'fs/promises';
import { join } from 'path';
import { PDFDocument } from 'pdf-lib';
import { Permission } from '@bookorbit/types';
import { CurrentUser } from '../../src/common/decorators/current-user.decorator';
import { RequirePermission } from '../../src/common/decorators/require-permission.decorator';
import type { RequestUser } from '../../src/common/types/request-user';
import { AppSettingsModule } from '../../src/modules/app-settings/app-settings.module';
import { AppSettingsService } from '../../src/modules/app-settings/app-settings.service';
import { BOOK_DOCK_FINALIZE_CHECKPOINT, type BookDockFinalizeCheckpoint } from '../../src/modules/book-dock/book-dock-finalize.service';

@Injectable()
class BookDockFixtureBoundary {
  private fault?: { phase: string; mode: string };
  arm(phase: string, mode: string) {
    if (!['published', 'committed', 'metadata'].includes(phase) || !['fail', 'crash'].includes(mode))
      throw new BadRequestException('Invalid import fault');
    this.fault = { phase, mode };
  }
  readonly checkpoint: BookDockFinalizeCheckpoint = (phase) => {
    if (this.fault?.phase !== phase) return Promise.resolve();
    const mode = this.fault.mode;
    this.fault = undefined;
    if (mode === 'crash') process.exit(86);
    return Promise.reject(new ServiceUnavailableException(`Controlled import interruption at ${phase}`));
  };
}

@Controller('__faults/book-dock')
@RequirePermission(Permission.ManageBookDock)
class BookDockFixtureController {
  constructor(
    private readonly boundary: BookDockFixtureBoundary,
    private readonly settings: AppSettingsService,
  ) {}
  @Post('arm/:phase/:mode')
  @HttpCode(204)
  arm(@CurrentUser() user: RequestUser, @Param('phase') phase: string, @Param('mode') mode: string) {
    this.owner(user);
    this.boundary.arm(phase, mode);
  }
  @Post('scanned-source')
  async source(@CurrentUser() user: RequestUser) {
    this.owner(user);
    const fileName = `Recovery scanned ${randomUUID()}.pdf`;
    const document = await PDFDocument.create();
    document.addPage([300, 400]).drawText('Durable scanned Book Dock fixture', { x: 20, y: 300 });
    const root = (await this.settings.getBookDockSettings()).bookDockPath;
    await mkdir(root, { recursive: true });
    await writeFile(join(root, fileName), await document.save(), { flag: 'wx' });
    return { fileName };
  }
  private owner(user: RequestUser): void {
    if (!user.isSuperuser) throw new ForbiddenException('Import faults require the isolated harness owner');
  }
}

@Global()
@Module({
  imports: [AppSettingsModule],
  providers: [
    BookDockFixtureBoundary,
    {
      provide: BOOK_DOCK_FINALIZE_CHECKPOINT,
      useFactory: (boundary: BookDockFixtureBoundary) => boundary.checkpoint,
      inject: [BookDockFixtureBoundary],
    },
  ],
  controllers: [BookDockFixtureController],
  exports: [BOOK_DOCK_FINALIZE_CHECKPOINT],
})
export class BookDockFinalizeFaultsModule {}
