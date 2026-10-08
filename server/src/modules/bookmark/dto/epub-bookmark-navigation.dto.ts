import { Type } from 'class-transformer';
import { IsIn, IsInt, IsOptional, IsString, Max, MaxLength, Min } from 'class-validator';
import type { EpubBookmarkNavigationQuery, EpubBookmarkSort } from '@bookorbit/types';

export class EpubBookmarkNavigationDto implements EpubBookmarkNavigationQuery {
  @Type(() => Number)
  @IsInt()
  @Min(1)
  @Max(2147483647)
  fileId!: number;

  @Type(() => Number)
  @IsInt()
  @Min(1)
  @Max(100)
  @IsOptional()
  limit?: number;

  @IsString()
  @MaxLength(200)
  @IsOptional()
  query?: string;

  @IsIn(['location', 'newest', 'oldest'])
  @IsOptional()
  sort?: EpubBookmarkSort;

  @IsString()
  @MaxLength(2048)
  @IsOptional()
  cursor?: string;

  @IsString()
  @MaxLength(2000)
  @IsOptional()
  currentCfi?: string;
}
