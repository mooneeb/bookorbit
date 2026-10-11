import { IsInt, IsOptional, Max, Min } from 'class-validator';
import type { UpdateBookRatingPayload } from '@bookorbit/types';

export class UpdateRatingDto implements UpdateBookRatingPayload {
  @IsOptional()
  @IsInt()
  @Min(1)
  @Max(5)
  rating?: number | null;

  @IsOptional()
  @IsInt()
  @Min(1)
  @Max(5)
  baseRating?: number | null;
}
