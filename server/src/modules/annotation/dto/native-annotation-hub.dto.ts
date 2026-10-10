import { Transform, Type } from 'class-transformer';
import { ArrayMaxSize, ArrayMinSize, IsArray, IsIn, IsInt, IsOptional, IsString, Max, MaxLength, Min } from 'class-validator';
import type { NativeAnnotationHubQuery, NativeAnnotationKind } from '@bookorbit/types';

export class NativeAnnotationHubQueryDto implements NativeAnnotationHubQuery {
  @IsOptional()
  @Type(() => Number)
  @IsInt()
  @Min(1)
  cursor?: number;

  @IsOptional()
  @Type(() => Number)
  @IsInt()
  @Min(1)
  @Max(100)
  limit?: number;

  @IsOptional()
  @IsString()
  @MaxLength(200)
  @Transform(({ value }) => (typeof value === 'string' ? value.trim() : value))
  search?: string;

  @IsOptional()
  @IsIn(['highlight', 'text_note', 'handwriting', 'pdf_ink'])
  kind?: NativeAnnotationKind;

  @IsOptional()
  @IsIn(['active', 'trashed', 'recovery'])
  status?: 'active' | 'trashed' | 'recovery';

  @IsOptional()
  @Type(() => Number)
  @IsInt()
  @Min(1)
  bookId?: number;

  @IsOptional()
  @Type(() => Number)
  @IsInt()
  @Min(1)
  fileId?: number;

  @IsOptional()
  @IsIn(['book', 'month', 'kind', 'source'])
  groupBy?: 'book' | 'month' | 'kind' | 'source';
}

export class NativeAnnotationHubExportQueryDto extends NativeAnnotationHubQueryDto {
  @IsOptional()
  @Transform(({ value }) => (typeof value === 'string' ? value.split(',').map(Number) : value))
  @IsArray()
  @ArrayMinSize(1)
  @ArrayMaxSize(100)
  @IsInt({ each: true })
  @Min(1, { each: true })
  ids?: number[];
}

export class NativeAnnotationHubDevicesQueryDto {
  @IsOptional()
  @Type(() => Number)
  @IsInt()
  @Min(1)
  @Max(100)
  limit?: number;

  @IsOptional()
  @IsString()
  @MaxLength(512)
  cursor?: string;

  @IsOptional()
  @Type(() => Number)
  @IsInt()
  @Min(1)
  bookId?: number;
}
