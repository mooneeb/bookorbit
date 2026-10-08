import type { ClearTtsPositionQuery } from '@bookorbit/types';
import { IsOptional, Matches } from 'class-validator';

export class ClearTtsPositionQueryDto implements ClearTtsPositionQuery {
  @IsOptional()
  @Matches(/^[a-f0-9]{64}$/)
  baseVersion?: string;
}
