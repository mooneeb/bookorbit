import { Type } from 'class-transformer';
import { IsInt, IsOptional, Max, Min } from 'class-validator';
import type { EpubBookmarkPageQuery } from '@bookorbit/types';

export class EpubBookmarkPageDto implements EpubBookmarkPageQuery {
  @Type(() => Number)
  @IsInt()
  @Min(1)
  @Max(100)
  @IsOptional()
  limit?: number;

  @Type(() => Number)
  @IsInt()
  @Min(1)
  @Max(2147483647)
  @IsOptional()
  beforeId?: number;
}
