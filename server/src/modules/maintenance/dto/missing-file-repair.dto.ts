import { IsInt, IsOptional, IsString, MaxLength, Min, MinLength } from 'class-validator';
import type { MissingFileRepairRequest } from '@bookorbit/types';

export class MissingFileRepairDto implements MissingFileRepairRequest {
  @IsInt()
  @Min(1)
  bookId: number;

  @IsInt()
  @Min(1)
  fileId: number;

  @IsString()
  @MinLength(1)
  @MaxLength(4096)
  replacementPath: string;

  @IsOptional()
  @IsString()
  @MaxLength(64)
  previewToken?: string;
}
