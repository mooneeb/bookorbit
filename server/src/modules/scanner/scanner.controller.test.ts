import { BadRequestException, ValidationPipe } from '@nestjs/common';
import { Test } from '@nestjs/testing';

import { ScannerController } from './scanner.controller';
import { ScannerService } from './scanner.service';
import { ScanHistoryQueryDto } from './dto/scan-history-query.dto';

describe('ScannerController', () => {
  let controller: ScannerController;
  let scannerService: {
    startScan: ReturnType<typeof vi.fn>;
    refreshCovers: ReturnType<typeof vi.fn>;
    getScanHistory: ReturnType<typeof vi.fn>;
  };

  beforeEach(async () => {
    scannerService = {
      startScan: vi.fn().mockResolvedValue({ jobId: 11 }),
      refreshCovers: vi.fn().mockResolvedValue({ queued: 3 }),
      getScanHistory: vi.fn().mockResolvedValue([]),
    };
    const module = await Test.createTestingModule({
      providers: [
        { provide: ScannerService, useValue: scannerService },
        {
          provide: ScannerController,
          useFactory: (service: ScannerService) => new ScannerController(service),
          inject: [ScannerService],
        },
      ],
    }).compile();
    controller = module.get(ScannerController);
  });

  it('delegates scan requests to ScannerService.startScan with manual trigger', () => {
    void controller.scan(42);

    expect(scannerService.startScan).toHaveBeenCalledWith(42, 'manual');
  });

  it('delegates scan history requests with the caller-supplied limit', () => {
    void controller.scanHistory(7, { limit: 5 });

    expect(scannerService.getScanHistory).toHaveBeenCalledWith(7, 5);
  });

  it('delegates cover refresh requests to ScannerService.refreshCovers', () => {
    void controller.refreshCovers(9);

    expect(scannerService.refreshCovers).toHaveBeenCalledWith(9);
  });

  describe('scan history query validation', () => {
    const pipe = new ValidationPipe({ whitelist: true, forbidNonWhitelisted: true, transform: true });
    const metadata = { type: 'query' as const, metatype: ScanHistoryQueryDto };

    it.each(['invalid', '1.5', 'NaN', 'Infinity', ['1', '2']])('rejects a noninteger limit %j before reading history', async (limit) => {
      await expect(pipe.transform({ limit }, metadata)).rejects.toThrow(BadRequestException);
      expect(scannerService.getScanHistory).not.toHaveBeenCalled();
    });

    it.each([undefined, '1', '5', '50000', '0', '-5'])('preserves the default and integer limits %j for bounded service handling', async (limit) => {
      const query: ScanHistoryQueryDto = await pipe.transform(limit === undefined ? {} : { limit }, metadata);

      await controller.scanHistory(7, query);

      expect(scannerService.getScanHistory).toHaveBeenCalledWith(7, limit === undefined ? 5 : Number(limit));
    });
  });
});
