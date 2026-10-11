import { Type } from 'class-transformer';
import { IsInt } from 'class-validator';

export class ScanHistoryQueryDto {
  @Type(() => Number)
  @IsInt()
  limit = 5;
}
