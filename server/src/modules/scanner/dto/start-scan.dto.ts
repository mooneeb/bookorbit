import { IsInt, IsOptional, Min } from 'class-validator';

export class StartScanDto {
  @IsOptional()
  @IsInt()
  @Min(0)
  expectedLastJobId?: number;
}
