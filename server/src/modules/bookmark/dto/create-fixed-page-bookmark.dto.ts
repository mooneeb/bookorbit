import { Transform } from 'class-transformer';
import { IsInt, IsNotEmpty, IsOptional, IsString, IsUUID, Max, MaxLength, Min } from 'class-validator';
import type { CreateFixedPageBookmarkPayload } from '@bookorbit/types';

export class CreateFixedPageBookmarkDto implements CreateFixedPageBookmarkPayload {
  @IsOptional()
  @IsUUID()
  clientId?: string;

  @IsInt()
  @Min(1)
  @Max(2147483647)
  fileId!: number;

  @IsInt()
  @Min(1)
  @Max(1000000)
  pageNumber!: number;

  @Transform(({ value }: { value: unknown }) => (typeof value === 'string' ? value.trim() : value))
  @IsString()
  @IsNotEmpty()
  @MaxLength(500)
  title!: string;
}
