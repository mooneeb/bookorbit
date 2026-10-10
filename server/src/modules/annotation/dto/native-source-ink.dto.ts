import { Transform, Type } from 'class-transformer';
import { IsInt, IsOptional, IsString, Matches, Max, Min } from 'class-validator';

export class NativeSourceInkScopeDto {
  @Type(() => Number)
  @IsInt()
  @Min(1)
  bookId!: number;

  @Type(() => Number)
  @IsInt()
  @Min(1)
  bookFileId!: number;
}

export class NativeSourceInkQueryDto extends NativeSourceInkScopeDto {
  @IsOptional()
  @IsString()
  @Matches(/^\d{1,15}$/)
  cursor?: string;

  @IsOptional()
  @Type(() => Number)
  @IsInt()
  @Min(1)
  @Max(100)
  limit?: number;

  @IsOptional()
  @Type(() => Number)
  @IsInt()
  @Min(0)
  page?: number;
}

export class NativeSourceInkWindowQueryDto extends NativeSourceInkScopeDto {
  @Transform(({ value }) => (typeof value === 'string' ? (value.trim() === '' ? Number.NaN : Number(value)) : value))
  @IsInt()
  @Min(0)
  @Max(Number.MAX_SAFE_INTEGER - 1)
  page!: number;

  @IsOptional()
  @Type(() => Number)
  @IsInt()
  @Min(1)
  @Max(Math.floor(Number.MAX_SAFE_INTEGER / 100))
  window?: number;

  @IsOptional()
  @Type(() => Number)
  @IsInt()
  @Min(1)
  @Max(100)
  limit?: number;
}
