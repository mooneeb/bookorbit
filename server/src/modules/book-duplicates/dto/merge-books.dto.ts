import { IsInt, IsOptional, IsString, Matches, Max, Min } from 'class-validator';
import type { MergeBooksRequest } from '@bookorbit/types';

export class MergeBooksDto implements MergeBooksRequest {
  @IsInt()
  @Min(1)
  @Max(2_147_483_647)
  sourceBookId!: number;

  @IsInt()
  @Min(1)
  @Max(2_147_483_647)
  targetBookId!: number;

  @IsOptional()
  @IsString()
  @Matches(/^[a-f0-9]{64}$/)
  previewToken?: string;
}
