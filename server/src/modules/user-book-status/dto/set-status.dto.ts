import { IsIn, IsString, Matches, ValidateIf } from 'class-validator';
import type { ReadStatus, SetBookReadingStatusPayload } from '@bookorbit/types';
import { READ_STATUSES } from '../user-book-status.constants';

export class SetStatusDto implements SetBookReadingStatusPayload {
  @ValidateIf((_, value) => value !== undefined)
  @IsIn(READ_STATUSES)
  status?: ReadStatus;

  @ValidateIf((_, value) => value !== null && value !== undefined)
  @IsString()
  @Matches(/^\d{4}-\d{2}-\d{2}$|^\d{4}-\d{2}-\d{2}T.+$/)
  startedAt?: string | null;

  @ValidateIf((_, value) => value !== null && value !== undefined)
  @IsString()
  @Matches(/^\d{4}-\d{2}-\d{2}$|^\d{4}-\d{2}-\d{2}T.+$/)
  finishedAt?: string | null;
}
