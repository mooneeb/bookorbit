import { Transform } from 'class-transformer';
import { IsInt, IsNotEmpty, IsString, Max, MaxLength, Min } from 'class-validator';
import type { CreateFixedPageBookmarkPayload } from '@bookorbit/types';

export class CreateFixedPageBookmarkDto implements CreateFixedPageBookmarkPayload {
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
