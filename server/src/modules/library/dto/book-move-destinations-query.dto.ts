import { Type, Transform } from 'class-transformer';
import { IsInt, IsOptional, IsString, Max, MaxLength, Min } from 'class-validator';
import type { BookMoveDestinationQuery, BookMoveFolderQuery } from '@bookorbit/types';

export class BookMoveFoldersQueryDto implements BookMoveFolderQuery {
  @Type(() => Number)
  @IsInt()
  @Min(0)
  @Max(1000000)
  page = 0;

  @Type(() => Number)
  @IsInt()
  @Min(1)
  @Max(100)
  size = 40;

  @IsOptional()
  @IsString()
  @MaxLength(200)
  @Transform(({ value }) => (typeof value === 'string' ? value.trim() : value))
  q?: string;
}

export class BookMoveDestinationsQueryDto extends BookMoveFoldersQueryDto implements BookMoveDestinationQuery {
  @Type(() => Number)
  @IsInt()
  @Min(1)
  sourceLibraryId!: number;
}
