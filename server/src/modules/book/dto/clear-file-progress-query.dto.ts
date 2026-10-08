import type { ClearFileProgressQuery } from '@bookorbit/types';
import { Matches, ValidateIf } from 'class-validator';

export class ClearFileProgressQueryDto implements ClearFileProgressQuery {
  @ValidateIf((query: ClearFileProgressQueryDto) => query.textVersion !== undefined || query.narrationVersion !== undefined)
  @Matches(/^[a-f0-9]{64}$/)
  textVersion?: string;

  @ValidateIf((query: ClearFileProgressQueryDto) => query.textVersion !== undefined || query.narrationVersion !== undefined)
  @Matches(/^[a-f0-9]{64}$/)
  narrationVersion?: string;
}
