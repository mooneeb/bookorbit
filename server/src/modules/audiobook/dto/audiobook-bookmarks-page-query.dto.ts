import { Type } from 'class-transformer';
import { IsInt, IsOptional, IsUUID, Max, Min } from 'class-validator';
import type { AudiobookBookmarksPageQuery } from '@bookorbit/types';

export class AudiobookBookmarksPageQueryDto implements AudiobookBookmarksPageQuery {
  @IsOptional()
  @Type(() => Number)
  @IsInt()
  @Min(1)
  @Max(100)
  limit = 40;

  @IsOptional()
  @IsUUID()
  afterId?: string;
}
