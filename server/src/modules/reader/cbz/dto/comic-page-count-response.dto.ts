import type { ComicPageCountResponse } from '@bookorbit/types';
import { IsInt, Min } from 'class-validator';

export class ComicPageCountResponseDto implements ComicPageCountResponse {
  @IsInt()
  @Min(0)
  pageCount!: number;
}
