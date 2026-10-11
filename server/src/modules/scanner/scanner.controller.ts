import { Permission } from '@bookorbit/types';
import { Body, Controller, Get, HttpCode, HttpStatus, Param, ParseIntPipe, Post, Query } from '@nestjs/common';

import { RequireLibraryAccess } from '../../common/decorators/require-library-access.decorator';
import { RequirePermission } from '../../common/decorators/require-permission.decorator';
import { RequireLibraryType } from '../../common/decorators/require-library-type.decorator';
import { ScannerService } from './scanner.service';
import { StartScanDto } from './dto/start-scan.dto';
import { ScanHistoryQueryDto } from './dto/scan-history-query.dto';

@Controller('scanner')
@RequireLibraryType('books')
export class ScannerController {
  constructor(private readonly scannerService: ScannerService) {}

  @Post('libraries/:id/scan')
  @RequirePermission(Permission.ManageLibraries)
  @RequireLibraryAccess('editor')
  @HttpCode(HttpStatus.ACCEPTED)
  scan(@Param('id', ParseIntPipe) libraryId: number, @Body() dto: StartScanDto = {}) {
    if (dto.expectedLastJobId !== undefined) {
      return this.scannerService.startScan(libraryId, 'manual', false, dto.expectedLastJobId);
    }
    return this.scannerService.startScan(libraryId, 'manual');
  }

  @Get('libraries/:id/scan-status')
  @RequirePermission(Permission.ManageLibraries)
  @RequireLibraryAccess('viewer')
  scanStatus(@Param('id', ParseIntPipe) libraryId: number) {
    return this.scannerService.getScanStatus(libraryId);
  }

  /**
   * Scan errors can name server paths, so this needs access to the library itself and not just the
   * global permission to manage libraries.
   */
  @Get('libraries/:id/scan-history')
  @RequirePermission(Permission.ManageLibraries)
  @RequireLibraryAccess('viewer')
  scanHistory(@Param('id', ParseIntPipe) libraryId: number, @Query() query: ScanHistoryQueryDto) {
    return this.scannerService.getScanHistory(libraryId, query.limit);
  }

  @Post('libraries/:id/refresh-covers')
  @RequirePermission(Permission.ManageLibraries)
  @RequireLibraryAccess('editor')
  @HttpCode(HttpStatus.ACCEPTED)
  refreshCovers(@Param('id', ParseIntPipe) libraryId: number) {
    return this.scannerService.refreshCovers(libraryId);
  }
}
